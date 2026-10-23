/*
    SPDX-FileCopyrightText: 2010 Fredrik Höglund <fredrik@kde.org>
    SPDX-FileCopyrightText: 2011 Philipp Knechtges <philipp-dev@knechtges.com>
    SPDX-FileCopyrightText: 2018 Alex Nemeth <alex.nemeth329@gmail.com>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

// plasma-glass's Liquid Glass effect: KWin 6.7.5's blur effect (plugins/blur) with the glass's bevel, frost and
// liquid, built as a plugin of its own (tools/kwin-effect.sh) so it can be swapped into a running KWin. It
// replaces the built-in blur (kwinrc [Plugins] blurEnabled=false, liquidglassEnabled=true) and reads its
// settings ([Effect-blur]), so System Settings' blur strength still applies.

#include "liquidglass.h"
// KConfigSkeleton
#include "liquidglassconfig.h"

#include "config-kwin.h"

#include <QCoreApplication>

#include "core/output.h"
#include "core/renderbackend.h"
#include "core/rendertarget.h"
#include "core/renderviewport.h"
#include "effect/effecthandler.h"
#include "opengl/glplatform.h"
#include "scene/backgroundeffectitem.h"
#include "scene/decorationitem.h"
#include "scene/scene.h"
#include "scene/surfaceitem.h"
#include "scene/windowitem.h"
#include "wayland/backgroundeffect_v1.h"
#include "wayland/display.h"
#include "wayland/surface.h"
#include "wayland_server.h"
#include "window.h"

#if KWIN_BUILD_X11
#include "utils/xcbutils.h"
#include "x11window.h"
#endif

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QGuiApplication>
#include <QMatrix4x4>
#include <QScreen>
#include <QTime>
#include <QTimer>
#include <QWindow>
#include <algorithm>
#include <chrono>
#include <cmath> // for ceil()
#include <cstdlib>

#include <KConfigGroup>
#include <KDirWatch>
#include <KSharedConfig>
#include <QStandardPaths>

#include <KDecoration3/Decoration>

Q_LOGGING_CATEGORY(KWIN_BLUR, "kwin_effect_liquidglass", QtWarningMsg)


namespace KWin
{

static const QByteArray s_blurAtomName = QByteArrayLiteral("_KDE_NET_WM_BLUR_BEHIND_REGION");

// plasma-glass's dark Liquid Glass Plasma style (theme/liquid-glass/generate.py): its glass rounds off at
// the edge, so the blur seen there is refracted and parts in colour, as through a lens. Its frames have
// rounded corners (generate.py R, 26 logical px; PANEL_R, 16, on the panel), which their mask, and so the
// blur region, leaves out.
static const QString s_liquidGlassTheme = QStringLiteral("liquid-glass");
// and Liquid Glass Light: its glass is frosted more and looks flat (a bevel only if [Light] asks for one),
// and the liquid's waves go beneath the frost: what's behind bends under them and an etched foil lights up
// in shards of colour where they crest, then the blur frosts it all. [Light] frost, refraction, diffraction,
// etch, saturation, bevelWidth, bevelRefraction, bevelDispersion, bevelSharpness
static const QString s_liquidGlassLightTheme = QStringLiteral("liquid-glass-light");
static const QVector4D s_lightBevel(24, 0, 0, 0);
static constexpr int s_lightFrost = 5;
static const QVector4D s_lightUnderlay(16, 1.2, 32, 0.8);
// the largest corner radius read off a blur region (logical px)
static constexpr qreal s_liquidGlassMaxRadius = 48;
// On thin glass (a panel, 44-46 px) the bevel takes up at most this share of the short side, its
// refraction shrinking with it, so the glass still has a flat middle and the bevel doesn't fold over
static constexpr qreal s_liquidGlassThinBevel = 0.35;
// The glass's look comes from these defaults, then ~/.config/plasma-glassrc's [Glass] group (which
// plasma-glass-tune edits; followed live), then the environment, to tune without touching the file.
// The bevel: logical px wide; how far in what's behind is seen at the very edge (refraction), how far red
// and blue part there each way (dispersion); how much sharper the edge shows it (0..1).
// [Glass] bevelWidth, refraction, dispersion, sharpness; KWIN_LIQUID_GLASS_BEVEL=width,refraction,dispersion,sharpness
static const QVector4D s_liquidGlassBevel(24, 9, 2, 1);
// The glass is frosted lightly all over, so what's behind still shows through and the bevel bends that
// same frost: a blur strength (BlurStrength's 1..15) it never goes above. [Glass] frost; KWIN_LIQUID_GLASS_FROST
static constexpr int s_liquidGlassFrost = 2;
// The liquid's waves lean the glass too: a fresh wave's steepest slope as far as the bevel at its edge
// (plasma-glassrc's [Ripple] amplitude, 1), and where a wave leans it fully, its colours part by a little
// more than the bevel's ([Ripple] aberration, logical px each way). KWIN_LIQUID_GLASS_RIPPLE=scale[,dispersion]
// overrides both (scale 0: no waves).
//
// The liquid (shaders/fluid.frag): ripples on cells this many logical px across, swell (the long waves
// that slosh) on cells this big; a fresh wave's steepest slope (the push's), which [Ripple] amplitude
// leans the glass by; the sponge along the rim that takes up the ripples [Ripple] reflection doesn't send
// back (px wide); how fast the level settles back after a moving rim (1/s); how strongly a window's moves
// slosh the swell and stir the ripples, at [Ripple] momentum 1 (as if the liquid were that much deeper:
// a change of speed of 1000 px/s sloshes the swell about as far as a push's wave leans the glass); and how
// fast the followers of the window's place and size take up its moves (Hz: its pointer's 60 Hz steps
// smoothed into a change of speed over about 0.15 s).
static constexpr double s_ripplesCell = 3;
static constexpr double s_swellCell = 8;
static constexpr double s_liquidSteep = 0.5;
static constexpr double s_pushSlope = 0.8;
static constexpr double s_liquidRim = 32;
static constexpr double s_liquidLevel = 1.0 / 3.0;
static constexpr double s_swellMomentum = 30;
static constexpr double s_ripplesMomentum = 0.15;
static constexpr double s_liquidFollow = 3;

// The corners a Liquid Glass frame rounds off a blur shape, by their radii (none: it's not one). A quarter
// circle of radius r leaves r² (1 - π/4) of the square it's in out of the shape, so what the shape leaves
// out of a square at each corner gives that corner's radius, to about a pixel, whichever frame it is.
static BorderRadius liquidGlassCorners(const RegionF &shape, const RectF &bounds)
{
    const qreal side = std::min({s_liquidGlassMaxRadius, bounds.width() / 2, bounds.height() / 2});
    const auto radius = [&](qreal x, qreal y) {
        const RectF square(x, y, side, side);
        qreal covered = 0;
        for (const RectF &rect : shape.rects()) {
            if (const RectF in = rect.intersected(square); !in.isEmpty()) {
                covered += in.width() * in.height();
            }
        }
        const qreal r = std::sqrt(std::max(side * side - covered, 0.0) / (1 - M_PI / 4));
        return r < 2 ? 0.0 : std::min(r, side);
    };
    return BorderRadius(radius(bounds.left(), bounds.top()), radius(bounds.right() - side, bounds.top()),
                        radius(bounds.right() - side, bounds.bottom() - side), radius(bounds.left(), bounds.bottom() - side));
}

// Seconds on the monotonic clock
static double monotonicNow()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static double smoothStep(double a, double b, double x)
{
    const double t = std::clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3 - 2 * t);
}

static QMatrix4x4 colorTransformMatrix(qreal saturation, qreal contrast)
{
    QMatrix4x4 saturationMatrix;
    QMatrix4x4 contrastMatrix;

    if (!qFuzzyCompare(saturation, 1.0)) {
        const qreal rval = (1.0 - saturation) * 0.2126;
        const qreal gval = (1.0 - saturation) * 0.7152;
        const qreal bval = (1.0 - saturation) * 0.0722;

        saturationMatrix = QMatrix4x4(rval + saturation, rval, rval, 0.0,
                                      gval, gval + saturation, gval, 0.0,
                                      bval, bval, bval + saturation, 0.0,
                                      0.0, 0.0, 0.0, 1.0);
    }

    if (!qFuzzyCompare(contrast, 1.0)) {
        const float transl = (1.0 - contrast) / 2.0;

        contrastMatrix = QMatrix4x4(contrast, 0.0, 0.0, 0.0,
                                    0.0, contrast, 0.0, 0.0,
                                    0.0, 0.0, contrast, 0.0,
                                    transl, transl, transl, 1.0);
    }

    return contrastMatrix * saturationMatrix;
}

LiquidGlassEffect::LiquidGlassEffect()
{
    LiquidGlassConfig::instance(effects->config());

    m_onscreenPass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                              QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                              QStringLiteral(PLASMA_GLASS_SHADERS "onscreen.frag"));
    if (!m_onscreenPass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load onscreen pass shader";
        return;
    } else {
        m_onscreenPass.mvpMatrixLocation = m_onscreenPass.shader->uniformLocation("modelViewProjectionMatrix");
        m_onscreenPass.colorMatrixLocation = m_onscreenPass.shader->uniformLocation("colorMatrix");
        m_onscreenPass.offsetLocation = m_onscreenPass.shader->uniformLocation("offset");
        m_onscreenPass.halfpixelLocation = m_onscreenPass.shader->uniformLocation("halfpixel");
    }

    m_roundedOnscreenPass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                                     QStringLiteral(PLASMA_GLASS_SHADERS "onscreen_rounded.vert"),
                                                                                     QStringLiteral(PLASMA_GLASS_SHADERS "onscreen_rounded.frag"));
    if (!m_roundedOnscreenPass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load onscreen pass shader";
        return;
    } else {
        m_roundedOnscreenPass.mvpMatrixLocation = m_roundedOnscreenPass.shader->uniformLocation("modelViewProjectionMatrix");
        m_roundedOnscreenPass.colorMatrixLocation = m_roundedOnscreenPass.shader->uniformLocation("colorMatrix");
        m_roundedOnscreenPass.offsetLocation = m_roundedOnscreenPass.shader->uniformLocation("offset");
        m_roundedOnscreenPass.halfpixelLocation = m_roundedOnscreenPass.shader->uniformLocation("halfpixel");
        m_roundedOnscreenPass.boxLocation = m_roundedOnscreenPass.shader->uniformLocation("box");
        m_roundedOnscreenPass.cornerRadiusLocation = m_roundedOnscreenPass.shader->uniformLocation("cornerRadius");
        m_roundedOnscreenPass.opacityLocation = m_roundedOnscreenPass.shader->uniformLocation("opacity");
    }

    // without it, Liquid Glass is blurred as any other surface is
    m_bevelOnscreenPass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                                   QStringLiteral(PLASMA_GLASS_SHADERS "onscreen_rounded.vert"),
                                                                                   QStringLiteral(PLASMA_GLASS_SHADERS "onscreen_bevel.frag"));
    if (!m_bevelOnscreenPass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load the Liquid Glass bevel shader";
    } else {
        m_bevelOnscreenPass.mvpMatrixLocation = m_bevelOnscreenPass.shader->uniformLocation("modelViewProjectionMatrix");
        m_bevelOnscreenPass.colorMatrixLocation = m_bevelOnscreenPass.shader->uniformLocation("colorMatrix");
        m_bevelOnscreenPass.offsetLocation = m_bevelOnscreenPass.shader->uniformLocation("offset");
        m_bevelOnscreenPass.halfpixelLocation = m_bevelOnscreenPass.shader->uniformLocation("halfpixel");
        m_bevelOnscreenPass.boxLocation = m_bevelOnscreenPass.shader->uniformLocation("box");
        m_bevelOnscreenPass.cornerRadiusLocation = m_bevelOnscreenPass.shader->uniformLocation("cornerRadius");
        m_bevelOnscreenPass.opacityLocation = m_bevelOnscreenPass.shader->uniformLocation("opacity");
        m_bevelOnscreenPass.sizeLocation = m_bevelOnscreenPass.shader->uniformLocation("size");
        m_bevelOnscreenPass.bevelLocation = m_bevelOnscreenPass.shader->uniformLocation("bevel");
        m_bevelOnscreenPass.sharpUnitLocation = m_bevelOnscreenPass.shader->uniformLocation("sharpUnit");
        m_bevelOnscreenPass.wavesUnitLocation = m_bevelOnscreenPass.shader->uniformLocation("wavesUnit");
        m_bevelOnscreenPass.rippleLocation = m_bevelOnscreenPass.shader->uniformLocation("ripple");
    }
    m_fluidPass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                           QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                           QStringLiteral(PLASMA_GLASS_SHADERS "fluid.frag"));
    if (!m_fluidPass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load the Liquid Glass fluid shader";
    } else {
        m_fluidPass.mvpMatrixLocation = m_fluidPass.shader->uniformLocation("modelViewProjectionMatrix");
        m_fluidPass.glassLocation = m_fluidPass.shader->uniformLocation("glass");
        m_fluidPass.cornersLocation = m_fluidPass.shader->uniformLocation("corners");
        m_fluidPass.cellLocation = m_fluidPass.shader->uniformLocation("cell");
        m_fluidPass.timingLocation = m_fluidPass.shader->uniformLocation("timing");
        m_fluidPass.dampingLocation = m_fluidPass.shader->uniformLocation("damping");
        m_fluidPass.accelLocation = m_fluidPass.shader->uniformLocation("accel");
        m_fluidPass.pushLocation = m_fluidPass.shader->uniformLocation("push");
        m_fluidPass.pressLocation = m_fluidPass.shader->uniformLocation("press");
        m_fluidPass.clickLocation = m_fluidPass.shader->uniformLocation("click");
        m_fluidPass.breezeLocation = m_fluidPass.shader->uniformLocation("breeze");
        m_fluidPass.shoreLocation = m_fluidPass.shader->uniformLocation("shore");
        m_fluidPass.bedLocation = m_fluidPass.shader->uniformLocation("bed");
    }
    m_surfacePass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                             QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                             QStringLiteral(PLASMA_GLASS_SHADERS "surface.frag"));
    if (!m_surfacePass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load the Liquid Glass surface shader";
    } else {
        m_surfacePass.mvpMatrixLocation = m_surfacePass.shader->uniformLocation("modelViewProjectionMatrix");
        m_surfacePass.ripplesLocation = m_surfacePass.shader->uniformLocation("ripples");
        m_surfacePass.swellLocation = m_surfacePass.shader->uniformLocation("swell");
        m_surfacePass.ripplesCellLocation = m_surfacePass.shader->uniformLocation("ripplesCell");
        m_surfacePass.swellCellLocation = m_surfacePass.shader->uniformLocation("swellCell");
        m_surfacePass.originLocation = m_surfacePass.shader->uniformLocation("origin");
        m_surfacePass.areaLocation = m_surfacePass.shader->uniformLocation("area");
        m_surfacePass.gainLocation = m_surfacePass.shader->uniformLocation("gain");
    }
    m_underlayPass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                              QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                              QStringLiteral(PLASMA_GLASS_SHADERS "underlay.frag"));
    if (!m_underlayPass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load the Liquid Glass Light underlay shader";
    } else {
        m_underlayPass.mvpMatrixLocation = m_underlayPass.shader->uniformLocation("modelViewProjectionMatrix");
        m_underlayPass.sizeLocation = m_underlayPass.shader->uniformLocation("size");
        m_underlayPass.originLocation = m_underlayPass.shader->uniformLocation("origin");
        m_underlayPass.areaLocation = m_underlayPass.shader->uniformLocation("area");
        m_underlayPass.leanLocation = m_underlayPass.shader->uniformLocation("lean");
        m_underlayPass.lightLocation = m_underlayPass.shader->uniformLocation("light");
        m_underlayPass.timeLocation = m_underlayPass.shader->uniformLocation("time");
        m_underlayPass.texUnitLocation = m_underlayPass.shader->uniformLocation("texUnit");
        m_underlayPass.wavesUnitLocation = m_underlayPass.shader->uniformLocation("wavesUnit");
    }
    m_bevel = s_liquidGlassBevel;
    m_frost = s_liquidGlassFrost;
    m_lightBevel = s_lightBevel;
    m_lightFrost = s_lightFrost;
    m_lightUnderlay = s_lightUnderlay;
    if (qEnvironmentVariableIsSet("KWIN_LIQUID_GLASS_RIPPLE")) {
        const QStringList ripple = qEnvironmentVariable("KWIN_LIQUID_GLASS_RIPPLE").split(QLatin1Char(','));
        m_rippleLean = ripple[0].toDouble();
        if (ripple.size() > 1) {
            m_rippleDispersion = ripple[1].toDouble();
        }
    }

    m_downsamplePass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                                QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                                QStringLiteral(PLASMA_GLASS_SHADERS "downsample.frag"));
    if (!m_downsamplePass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load downsampling pass shader";
        return;
    } else {
        m_downsamplePass.mvpMatrixLocation = m_downsamplePass.shader->uniformLocation("modelViewProjectionMatrix");
        m_downsamplePass.offsetLocation = m_downsamplePass.shader->uniformLocation("offset");
        m_downsamplePass.halfpixelLocation = m_downsamplePass.shader->uniformLocation("halfpixel");
    }

    m_upsamplePass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                              QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                              QStringLiteral(PLASMA_GLASS_SHADERS "upsample.frag"));
    if (!m_upsamplePass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load upsampling pass shader";
        return;
    } else {
        m_upsamplePass.mvpMatrixLocation = m_upsamplePass.shader->uniformLocation("modelViewProjectionMatrix");
        m_upsamplePass.offsetLocation = m_upsamplePass.shader->uniformLocation("offset");
        m_upsamplePass.halfpixelLocation = m_upsamplePass.shader->uniformLocation("halfpixel");
    }

    m_noisePass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture,
                                                                           QStringLiteral(PLASMA_GLASS_SHADERS "vertex.vert"),
                                                                           QStringLiteral(PLASMA_GLASS_SHADERS "noise.frag"));
    if (!m_noisePass.shader) {
        qCWarning(KWIN_BLUR) << "Failed to load noise pass shader";
        return;
    } else {
        m_noisePass.mvpMatrixLocation = m_noisePass.shader->uniformLocation("modelViewProjectionMatrix");
        m_noisePass.noiseTextureSizeLocation = m_noisePass.shader->uniformLocation("noiseTextureSize");
    }

    initBlurStrengthValues();
    reconfigure(ReconfigureAll);

#if KWIN_BUILD_X11
    if (effects->xcbConnection()) {
        net_wm_blur_region = effects->announceSupportProperty(s_blurAtomName, this);
    }
#endif

    waylandServer()->backgroundEffectManager()->addBlurCapability();

    connect(effects, &EffectsHandler::windowAdded, this, &LiquidGlassEffect::slotWindowAdded);
    connect(effects, &EffectsHandler::windowDeleted, this, &LiquidGlassEffect::slotWindowDeleted);
    connect(effects, &EffectsHandler::mouseChanged, this, &LiquidGlassEffect::slotMouseChanged);
    connect(effects, &EffectsHandler::viewRemoved, this, &LiquidGlassEffect::slotViewRemoved);
#if KWIN_BUILD_X11
    connect(effects, &EffectsHandler::propertyNotify, this, &LiquidGlassEffect::slotPropertyNotify);
    connect(effects, &EffectsHandler::xcbConnectionChanged, this, [this]() {
        net_wm_blur_region = effects->announceSupportProperty(s_blurAtomName, this);
    });
#endif

    // Fetch the blur regions for all windows
    const auto stackingOrder = effects->stackingOrder();
    for (EffectWindow *window : stackingOrder) {
        slotWindowAdded(window);
    }

    // Follow the Plasma style: only the dark Liquid Glass has the bevel. Watched as a file, since its
    // settings page doesn't notify about the change; and the glass's own settings, which
    // plasma-glass-tune writes as you move its sliders.
    m_plasmarc = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/plasmarc");
    m_glassrc = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/plasma-glassrc");
    KDirWatch::self()->addFile(m_plasmarc);
    KDirWatch::self()->addFile(m_glassrc);
    const auto configChanged = [this](const QString &path) {
        if (path == m_plasmarc) {
            updateLiquidGlass();
        } else if (path == m_glassrc) {
            loadLiquidGlassSettings();
        }
    };
    connect(KDirWatch::self(), &KDirWatch::dirty, this, configChanged);
    connect(KDirWatch::self(), &KDirWatch::created, this, configChanged);
    connect(KDirWatch::self(), &KDirWatch::deleted, this, configChanged);
    updateLiquidGlass();
    loadLiquidGlassSettings();
    QDBusConnection::sessionBus().registerObject(QStringLiteral("/org/kde/KWin/LiquidGlass"), QStringLiteral("org.kde.KWin.LiquidGlass"),
                                                 this, QDBusConnection::ExportScriptableSlots);

    m_valid = true;
}

LiquidGlassEffect::~LiquidGlassEffect()
{
    if (!m_plasmarc.isEmpty()) {
        KDirWatch::self()->removeFile(m_plasmarc);
        KDirWatch::self()->removeFile(m_glassrc);
        QDBusConnection::sessionBus().unregisterObject(QStringLiteral("/org/kde/KWin/LiquidGlass"));
    }
    waylandServer()->backgroundEffectManager()->removeBlurCapability();
}

void LiquidGlassEffect::updateLiquidGlass()
{
    KSharedConfig::Ptr plasmarc = KSharedConfig::openConfig(QStringLiteral("plasmarc"), KConfig::NoGlobals);
    plasmarc->reparseConfiguration();
    const QString style = plasmarc->group(QStringLiteral("Theme")).readEntry("name", QString());
    const bool liquidGlass = style == s_liquidGlassTheme;
    const bool light = style == s_liquidGlassLightTheme;
    if (liquidGlass != m_liquidGlass || light != m_liquidGlassLight) {
        m_liquidGlass = liquidGlass;
        m_liquidGlassLight = light;
        effects->addRepaintFull();
    }
}

void LiquidGlassEffect::loadLiquidGlassSettings()
{
    KSharedConfig::Ptr glassrc = KSharedConfig::openConfig(QStringLiteral("plasma-glassrc"), KConfig::NoGlobals);
    glassrc->reparseConfiguration();
    const KConfigGroup glass = glassrc->group(QStringLiteral("Glass"));
    QVector4D bevel(glass.readEntry("bevelWidth", double(s_liquidGlassBevel.x())), glass.readEntry("refraction", double(s_liquidGlassBevel.y())),
                    glass.readEntry("dispersion", double(s_liquidGlassBevel.z())), glass.readEntry("sharpness", double(s_liquidGlassBevel.w())));
    int frost = glass.readEntry("frost", s_liquidGlassFrost);
    if (const QStringList env = qEnvironmentVariable("KWIN_LIQUID_GLASS_BEVEL").split(QLatin1Char(',')); env.size() == 4) {
        bevel = QVector4D(env[0].toFloat(), env[1].toFloat(), env[2].toFloat(), env[3].toFloat());
    }
    if (const int envFrost = qEnvironmentVariableIntValue("KWIN_LIQUID_GLASS_FROST"); envFrost > 0) {
        frost = envFrost;
    }
    // a bevel at least 1 px wide (the shader divides by it), sharpness a share
    bevel = QVector4D(std::max(bevel.x(), 1.0f), std::max(bevel.y(), 0.0f), std::max(bevel.z(), 0.0f), std::clamp(bevel.w(), 0.0f, 1.0f));
    frost = std::clamp(frost, 1, 15);

    const KConfigGroup light = glassrc->group(QStringLiteral("Light"));
    const QVector4D lightBevel(std::max(light.readEntry("bevelWidth", double(s_lightBevel.x())), 1.0),
                               std::max(light.readEntry("bevelRefraction", double(s_lightBevel.y())), 0.0),
                               std::max(light.readEntry("bevelDispersion", double(s_lightBevel.z())), 0.0),
                               std::clamp(light.readEntry("bevelSharpness", double(s_lightBevel.w())), 0.0, 1.0));
    const int lightFrost = std::clamp(light.readEntry("frost", s_lightFrost), 1, 15);
    const QVector4D lightUnderlay(std::max(light.readEntry("refraction", double(s_lightUnderlay.x())), 0.0),
                                  std::max(light.readEntry("diffraction", double(s_lightUnderlay.y())), 0.0),
                                  std::max(light.readEntry("etch", double(s_lightUnderlay.z())), 2.0),
                                  std::clamp(light.readEntry("saturation", double(s_lightUnderlay.w())), 0.0, 1.0));

    // the liquid's: it takes them at its next step
    const KConfigGroup ripple = glassrc->group(QStringLiteral("Ripple"));
    const auto number = [&ripple](const char *key, double fallback, double low, double high) {
        return std::clamp(ripple.readEntry(key, fallback), low, high);
    };
    m_liquid.speed = number("speed", 120, 20, 1000);
    m_liquid.width = number("width", 21, 2, 300);
    m_liquid.interval = number("interval", 1.2, 0.2, 60);
    m_liquid.damping = number("damping", 36, 0.2, 600);
    m_liquid.reflection = number("reflection", 0.3, 0, 1);
    m_liquid.amplitude = number("amplitude", 1, 0, 5);
    m_liquid.aberration = number("aberration", 3, 0, 30);
    m_liquid.strike = number("strike", 1, 1, 4000);
    m_liquid.jitter = number("jitter", 0.6, 0, 1);
    m_liquid.chop = number("chop", 0.3, 0, 5);
    m_liquid.chopScale = number("chopScale", 40, 4, 400);
    m_liquid.shore = number("shore", 8, 0, 60);
    m_liquid.shoreScale = number("shoreScale", 120, 10, 1000);
    m_liquid.floor = number("floor", 0.35, 0, 0.8);
    m_liquid.floorScale = number("floorScale", 220, 20, 2000);
    m_liquid.press = ripple.readEntry("stir", QStringLiteral("push")) == QLatin1String("press");
    m_liquid.momentum = number("momentum", 1, 0, 5);
    m_liquid.sloshSpeed = number("sloshSpeed", 900, 100, 4000);
    m_liquid.sloshDamping = number("sloshDamping", 1.5, 0.1, 60);
    m_liquid.click = number("click", 1, 0, 5);
    m_liquid.clickWidth = number("clickWidth", 24, 2, 200);

    if (bevel != m_bevel || frost != m_frost || lightBevel != m_lightBevel || lightFrost != m_lightFrost || lightUnderlay != m_lightUnderlay) {
        m_bevel = bevel;
        m_frost = frost;
        m_lightBevel = lightBevel;
        m_lightFrost = lightFrost;
        m_lightUnderlay = lightUnderlay;
        effects->addRepaintFull();
    }
}

QString LiquidGlassEffect::Build() const
{
    return QStringLiteral(PLASMA_GLASS_BUILD_ID);
}

void LiquidGlassEffect::Stir(bool busy, int side, double at)
{
    if (!calledFromDBus()) {
        return;
    }
    const QDBusReply<uint> pid = connection().interface()->servicePid(message().service());
    if (!pid.isValid()) {
        return;
    }
    // kept by process, for the windows it shows later too (KRunner's is a new one each time it opens)
    LiquidGlassClient &client = m_liquidGlassClients[pid_t(pid.value())];
    client.busy = busy;
    client.side = std::clamp(side, 0, 3);
    client.at = at;
    for (auto &[window, data] : m_windows) {
        if (window->pid() == pid_t(pid.value())) {
            window->addRepaintFull();
        }
    }
}

void LiquidGlassEffect::initBlurStrengthValues()
{
    // This function creates an array of blur strength values that are evenly distributed

    // The range of the slider on the blur settings UI
    int numOfBlurSteps = 15;
    int remainingSteps = numOfBlurSteps;

    /*
     * Explanation for these numbers:
     *
     * The texture blur amount depends on the downsampling iterations and the offset value.
     * By changing the offset we can alter the blur amount without relying on further downsampling.
     * But there is a minimum and maximum value of offset per downsample iteration before we
     * get artifacts.
     *
     * The minOffset variable is the minimum offset value for an iteration before we
     * get blocky artifacts because of the downsampling.
     *
     * The maxOffset value is the maximum offset value for an iteration before we
     * get diagonal line artifacts because of the nature of the dual kawase blur algorithm.
     *
     * The expandSize value is the minimum value for an iteration before we reach the end
     * of a texture in the shader and sample outside of the area that was copied into the
     * texture from the screen.
     */

    // {minOffset, maxOffset, expandSize}
    blurOffsets.append({1.0, 2.0, 10}); // Down sample size / 2
    blurOffsets.append({2.0, 3.0, 20}); // Down sample size / 4
    blurOffsets.append({2.0, 5.0, 50}); // Down sample size / 8
    blurOffsets.append({3.0, 8.0, 150}); // Down sample size / 16
    // blurOffsets.append({5.0, 10.0, 400}); // Down sample size / 32
    // blurOffsets.append({7.0, ?.0});       // Down sample size / 64

    float offsetSum = 0;

    for (int i = 0; i < blurOffsets.size(); i++) {
        offsetSum += blurOffsets[i].maxOffset - blurOffsets[i].minOffset;
    }

    for (int i = 0; i < blurOffsets.size(); i++) {
        int iterationNumber = std::ceil((blurOffsets[i].maxOffset - blurOffsets[i].minOffset) / offsetSum * numOfBlurSteps);
        remainingSteps -= iterationNumber;

        if (remainingSteps < 0) {
            iterationNumber += remainingSteps;
        }

        float offsetDifference = blurOffsets[i].maxOffset - blurOffsets[i].minOffset;

        for (int j = 1; j <= iterationNumber; j++) {
            // {iteration, offset}
            blurStrengthValues.append({i + 1, blurOffsets[i].minOffset + (offsetDifference / iterationNumber) * j});
        }
    }
}

void LiquidGlassEffect::reconfigure(ReconfigureFlags flags)
{
    LiquidGlassConfig::self()->read();

    int blurStrength = LiquidGlassConfig::blurStrength() - 1;
    m_iterationCount = blurStrengthValues[blurStrength].iteration;
    m_offset = blurStrengthValues[blurStrength].offset;
    m_expandSize = blurOffsets[m_iterationCount - 1].expandSize;
    m_noiseStrength = LiquidGlassConfig::noiseStrength();
    m_colorMatrix = colorTransformMatrix(LiquidGlassConfig::saturation() / 100.0, 1.0);
    for (auto &[window, data] : m_windows) {
        data.blurItem->setPixelsToExpandRepaintsBelowOpaqueRegions(m_expandSize);
    }

    // Update all windows for the blur to take effect
    effects->addRepaintFull();
}

void LiquidGlassEffect::updateBlurRegion(EffectWindow *w)
{
    std::optional<RegionF> content;
    std::optional<RegionF> frame;

#if KWIN_BUILD_X11
    if (net_wm_blur_region != XCB_ATOM_NONE) {
        if (const auto x11Window = qobject_cast<X11Window *>(w->window())) {
            Xcb::Property wmBlurRegionProperty(false, x11Window->window(), net_wm_blur_region, XCB_ATOM_CARDINAL, 0, 32768);
            if (const auto cardinals = wmBlurRegionProperty.array<uint32_t>()) {
                if (cardinals->size() == 0 || cardinals->size() == 1) {
                    // It means blur background behind whole window.
                    content = RegionF();
                } else if (cardinals->size() % 4 == 0) {
                    RegionF region;
                    for (uint i = 0; i < cardinals->size();) {
                        const int x = (*cardinals)[i++];
                        const int y = (*cardinals)[i++];
                        const int w = (*cardinals)[i++];
                        const int h = (*cardinals)[i++];
                        region += Xcb::fromXNative(Rect(x, y, w, h));
                    }
                    content = region;
                }
            }
        }
    }
#endif

    if (SurfaceInterface *surface = w->surface()) {
        if (!surface->blurRegion().isEmpty()) {
            content = surface->blurRegion();
        }
    }

    if (auto internal = w->internalWindow()) {
        const auto property = internal->property("kwin_blur");
        if (property.isValid()) {
            content = property.value<RegionF>();
        }
    }

    if (w->decorationHasAlpha() && decorationSupportsBlurBehind(w)) {
        frame = decorationBlurRegion(w);
    }

    if (content.has_value() || frame.has_value()) {
        BlurEffectData &data = m_windows[w];
        data.content = content;
        data.frame = frame;
        if (!data.blurItem) {
            data.blurItem = std::make_unique<BackgroundEffectItem>(w->windowItem());
        }
        data.blurItem->setPixelsToExpandRepaintsBelowOpaqueRegions(m_expandSize);
        data.blurItem->setEffectBoundingRect(blurRegion(w).boundingRect());
    } else {
        if (auto it = m_windows.find(w); it != m_windows.end()) {
            effects->makeOpenGLContextCurrent();
            m_windows.erase(it);
        }
    }
}

void LiquidGlassEffect::slotWindowAdded(EffectWindow *w)
{
    SurfaceInterface *surf = w->surface();

    if (surf) {
        windowBlurChangedConnections[w] = connect(surf, &SurfaceInterface::blurChanged, this, [this, w]() {
            if (w) {
                updateBlurRegion(w);
            }
        });
    }
    if (auto internal = w->internalWindow()) {
        internal->installEventFilter(this);
    }

    setupDecorationConnections(w);
    connect(w, &EffectWindow::windowDecorationChanged, this, [this, w]() {
        setupDecorationConnections(w);
        updateBlurRegion(w);
    });

    updateBlurRegion(w);
}

void LiquidGlassEffect::slotWindowDeleted(EffectWindow *w)
{
    if (w == m_clickWindow) {
        m_clickWindow = nullptr;
    }
    if (auto it = m_windows.find(w); it != m_windows.end()) {
        effects->makeOpenGLContextCurrent();
        m_windows.erase(it);
    }
    if (auto it = windowBlurChangedConnections.find(w); it != windowBlurChangedConnections.end()) {
        disconnect(*it);
        windowBlurChangedConnections.erase(it);
    }
}

void LiquidGlassEffect::slotMouseChanged(const QPointF &pos, const QPointF &oldpos, Qt::MouseButtons buttons, Qt::MouseButtons oldbuttons,
                                  Qt::KeyboardModifiers modifiers, Qt::KeyboardModifiers oldmodifiers)
{
    Q_UNUSED(modifiers)
    Q_UNUSED(oldmodifiers)
    const bool pressed = (buttons & Qt::LeftButton) && !(oldbuttons & Qt::LeftButton);
    const bool released = !(buttons & Qt::LeftButton) && (oldbuttons & Qt::LeftButton);
    if (m_clickWindow && (buttons & Qt::LeftButton) && (oldbuttons & Qt::LeftButton) && pos != oldpos) {
        // dragged: the press follows the pointer (off the glass, it presses on nothing), the last half second
        // kept for the liquid's steps to place it between
        if (auto it = m_windows.find(m_clickWindow); it != m_windows.end() && it->second.click.down >= 0) {
            auto &path = it->second.click.path;
            const double now = monotonicNow();
            path.emplace_back(now, pos - it->second.click.origin);
            while (path.size() > 2 && path[1].first < now - 0.5) {
                path.pop_front();
            }
        }
    }
    if (released && m_clickWindow) {
        // the press lets go
        if (auto it = m_windows.find(m_clickWindow); it != m_windows.end() && it->second.click.down >= 0 && it->second.click.up < 0) {
            it->second.click.up = monotonicNow();
            m_clickWindow->addRepaintFull();
        }
        m_clickWindow = nullptr;
    }
    if (!pressed || !(m_liquidGlass || m_liquidGlassLight) || m_liquid.click <= 0 || !m_fluidPass.shader || !m_bevelOnscreenPass.shader) {
        return;
    }
    // the window the press lands on, the topmost there; it presses on the liquid if that's a Liquid Glass
    // surface (as blur() tells one) and the press is on its glass
    const QList<EffectWindow *> stack = effects->stackingOrder();
    for (auto it = stack.crbegin(); it != stack.crend(); ++it) {
        EffectWindow *w = *it;
        if (w->isDeleted() || !w->isVisible() || w->isMinimized() || !w->isOnCurrentDesktop() || !w->frameGeometry().contains(pos)) {
            continue;
        }
        const auto data = m_windows.find(w);
        if (data == m_windows.end() || !w->window()->borderRadius().isNull()) {
            return;
        }
        RegionF shape = blurRegion(w);
        shape.translate(w->pos());
        const RectF glass = shape.boundingRect();
        if (!shape.contains(pos) || (liquidGlassCorners(shape, glass).isNull() && !w->isDock())) {
            return;
        }
        data->second.click.down = monotonicNow();
        data->second.click.up = -1;
        data->second.click.origin = glass.topLeft();
        data->second.click.path = {{data->second.click.down, pos - glass.topLeft()}};
        m_clickWindow = w;
        w->addRepaintFull();
        return;
    }
}

void LiquidGlassEffect::slotViewRemoved(KWin::RenderView *view)
{
    for (auto &[window, data] : m_windows) {
        if (auto it = data.render.find(view); it != data.render.end()) {
            effects->makeOpenGLContextCurrent();
            data.render.erase(it);
        }
    }
}

#if KWIN_BUILD_X11
void LiquidGlassEffect::slotPropertyNotify(EffectWindow *w, long atom)
{
    if (w && atom == net_wm_blur_region && net_wm_blur_region != XCB_ATOM_NONE) {
        updateBlurRegion(w);
    }
}
#endif

void LiquidGlassEffect::setupDecorationConnections(EffectWindow *w)
{
    if (!w->decoration()) {
        return;
    }

    connect(w->decoration(), &KDecoration3::Decoration::blurRegionChanged, this, [this, w]() {
        updateBlurRegion(w);
    });
}

bool LiquidGlassEffect::eventFilter(QObject *watched, QEvent *event)
{
    auto internal = qobject_cast<QWindow *>(watched);
    if (internal && event->type() == QEvent::DynamicPropertyChange) {
        QDynamicPropertyChangeEvent *pe = static_cast<QDynamicPropertyChangeEvent *>(event);
        if (pe->propertyName() == "kwin_blur") {
            if (auto w = effects->findWindow(internal)) {
                updateBlurRegion(w);
            }
        }
    }
    return false;
}

bool LiquidGlassEffect::enabledByDefault()
{
    const auto context = effects->openglContext();
    if (!context || context->isSoftwareRenderer()) {
        return false;
    }
    GLPlatform *gl = context->glPlatform();

    if (gl->isIntel() && gl->chipClass() < SandyBridge) {
        return false;
    }
    if (gl->isPanfrost() && gl->chipClass() <= MaliT8XX) {
        return false;
    }
    // The blur effect works, but is painfully slow (FPS < 5) on Mali and VideoCore
    if (gl->isLima() || gl->isVideoCore4() || gl->isVideoCore3D()) {
        return false;
    }
    return true;
}

bool LiquidGlassEffect::supported()
{
    // only in the KWin it was built against: another one's classes may be laid out differently
    // (tools/kwin-effect.sh rebuilds it after every KWin update)
    return effects->isOpenGLCompositing() && QCoreApplication::applicationVersion() == KWIN_VERSION_STRING;
}

bool LiquidGlassEffect::decorationSupportsBlurBehind(const EffectWindow *w) const
{
    return w->decoration() && !w->decoration()->blurRegion().isNull();
}

RegionF LiquidGlassEffect::decorationBlurRegion(const EffectWindow *w) const
{
    if (!decorationSupportsBlurBehind(w)) {
        return RegionF();
    }

    RegionF decorationRegion = RegionF(w->decoration()->rect()) - w->contentsRect();
    //! we return only blurred regions that belong to decoration region
    return decorationRegion.intersected(RegionF(w->decoration()->blurRegion()));
}

RegionF LiquidGlassEffect::blurRegion(EffectWindow *w) const
{
    RegionF region;

    if (auto it = m_windows.find(w); it != m_windows.end()) {
        const std::optional<RegionF> &content = it->second.content;
        const std::optional<RegionF> &frame = it->second.frame;
        if (content.has_value()) {
            if (content->isEmpty()) {
                // An empty region means that the blur effect should be enabled
                // for the whole window.
                region = w->contentsRect();
            } else {
                region = content->translated(w->contentsRect().topLeft()) & w->contentsRect();
            }
            if (frame.has_value()) {
                region += frame.value();
            }
        } else if (frame.has_value()) {
            region = frame.value();
        }
    }

    return region;
}

void LiquidGlassEffect::prePaintScreen(ScreenPrePaintData &data)
{
    m_currentView = data.view;
    // plasma-glass: the liquid runs up to when this frame shows, in steps as even as the screen's refreshes
    m_frameTime = data.frame ? std::chrono::duration<double>(data.frame->targetPageflipTime().time_since_epoch()).count() : monotonicNow();

    effects->prePaintScreen(data);
}

bool LiquidGlassEffect::shouldBlur(const EffectWindow *w, int mask, const WindowPaintData &data) const
{
    if (effects->activeFullScreenEffect() && !w->data(WindowForceBlurRole).toBool()) {
        return false;
    }

    if (w->isDesktop()) {
        return false;
    }

    bool scaled = !qFuzzyCompare(data.xScale(), 1.0) && !qFuzzyCompare(data.yScale(), 1.0);
    bool translated = data.xTranslation() || data.yTranslation();

    if ((scaled || (translated || (mask & PAINT_WINDOW_TRANSFORMED))) && !w->data(WindowForceBlurRole).toBool()) {
        return false;
    }

    return true;
}

void LiquidGlassEffect::drawWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data)
{
    blur(renderTarget, viewport, w, mask, deviceRegion, data);

    // Draw the window over the blurred area
    effects->drawWindow(renderTarget, viewport, w, mask, deviceRegion, data);
}

GLTexture *LiquidGlassEffect::ensureNoiseTexture()
{
    if (m_noiseStrength == 0) {
        return nullptr;
    }

    const qreal scale = std::max(1.0, QGuiApplication::primaryScreen()->logicalDotsPerInch() / 96.0);
    if (!m_noisePass.noiseTexture || m_noisePass.noiseTextureScale != scale || m_noisePass.noiseTextureStength != m_noiseStrength) {
        // Init randomness based on time
        std::srand((uint)QTime::currentTime().msec());

        QImage noiseImage(QSize(256, 256), QImage::Format_Grayscale8);

        for (int y = 0; y < noiseImage.height(); y++) {
            uint8_t *noiseImageLine = (uint8_t *)noiseImage.scanLine(y);

            for (int x = 0; x < noiseImage.width(); x++) {
                noiseImageLine[x] = std::rand() % m_noiseStrength;
            }
        }

        noiseImage = noiseImage.scaled(noiseImage.size() * scale);

        m_noisePass.noiseTexture = GLTexture::upload(noiseImage);
        if (!m_noisePass.noiseTexture) {
            return nullptr;
        }
        m_noisePass.noiseTexture->setFilter(GL_NEAREST);
        m_noisePass.noiseTexture->setWrapMode(GL_REPEAT);
        m_noisePass.noiseTextureScale = scale;
        m_noisePass.noiseTextureStength = m_noiseStrength;
    }

    return m_noisePass.noiseTexture.get();
}

// plasma-glass: where a follower is dt s on, and how fast it goes (it closes in on its target critically
// damped, at omega 1/s; exact while the target holds, as it does between frames)
static double followerAt(const LiquidGlassFollower &follower, double dt, double omega, double *velocity = nullptr)
{
    const double e0 = follower.x - follower.target;
    const double k = std::exp(-omega * dt);
    if (velocity) {
        *velocity = (follower.v - omega * (follower.v + omega * e0) * dt) * k;
    }
    return follower.target + (e0 + (follower.v + omega * e0) * dt) * k;
}

// 0..1, the same for the same n
static double hash01(quint32 n)
{
    n ^= n >> 16;
    n *= 0x7feb352dU;
    n ^= n >> 15;
    n *= 0x846ca68bU;
    n ^= n >> 16;
    return n / 4294967296.0;
}

// how long the ripples take to settle after the last push (to about 5%, e^-3, and then they fade out over
// 2 s): they fade with time, and lose what the rim doesn't send back each time they reach it
double LiquidGlassEffect::liquidSettleTime(const RectF &glass) const
{
    const double crossing = std::max(10.0, (glass.width() + glass.height()) / 2) / m_liquid.speed;
    const double ripples = 1 / m_liquid.damping - std::log(std::max(m_liquid.reflection, 0.02)) / crossing;
    return std::min(3 / ripples, 15.0);
}

// Runs a layer of the liquid on for span s, in even steps of at most maxStep s; uniforms(t, dt) sets the
// fluid pass's uniforms for the step from t s into the span. The layer grows to hold `cells` (keeping
// what's in it) and starts at rest.
void LiquidGlassEffect::stepLiquid(LiquidGlassLayer &layer, const QSize &cells, double cell, double span, double maxStep, const std::function<void(double t, double dt)> &uniforms, GLVertexBuffer *vbo)
{
    std::unique_ptr<GLTexture> kept;
    GLTexture *source = layer.textures[layer.current].get();
    if (!source || source->width() < cells.width() || source->height() < cells.height()) {
        // a larger pair of textures (in steps of 16 cells), the first step reading the old state (fluid.frag
        // takes cells past it as dry)
        const auto room = [](int need, int have) {
            return (std::max(need, have) + 15) / 16 * 16;
        };
        const QSize size(room(cells.width(), source ? source->width() : 0), room(cells.height(), source ? source->height() : 0));
        kept = std::move(layer.textures[layer.current]);
        layer = LiquidGlassLayer();
        for (int i = 0; i < 2; ++i) {
            layer.textures[i] = GLTexture::allocate(GL_RGBA32F, size);
            if (!layer.textures[i]) {
                qCWarning(KWIN_BLUR) << "Failed to allocate the Liquid Glass fluid";
                layer = LiquidGlassLayer();
                return;
            }
            layer.textures[i]->setFilter(GL_LINEAR); // surface.frag samples it smoothly (fluid.frag fetches texels)
            layer.textures[i]->setWrapMode(GL_CLAMP_TO_EDGE);
            layer.framebuffers[i] = std::make_unique<GLFramebuffer>(layer.textures[i].get());
            if (!layer.framebuffers[i]->valid()) {
                layer = LiquidGlassLayer();
                return;
            }
        }
        layer.current = 1; // the first step writes the other one
        source = kept.get();
        if (!source) {
            source = layer.textures[1].get();
            GLFramebuffer::pushFramebuffer(layer.framebuffers[1].get());
            glClearColor(0, 0, 0, 0);
            glClear(GL_COLOR_BUFFER_BIT);
            GLFramebuffer::popFramebuffer();
        }
    }

    const int steps = std::max(1, int(std::ceil(span / maxStep)));
    const double dt = span / steps;
    glActiveTexture(GL_TEXTURE0);
    ShaderManager::instance()->pushShader(m_fluidPass.shader.get());
    m_fluidPass.shader->setUniform(m_fluidPass.cellLocation, float(cell));
    for (int i = 0; i < steps; ++i) {
        uniforms(i * dt, dt);
        const int next = 1 - layer.current;
        source->bind();
        GLFramebuffer::pushFramebuffer(layer.framebuffers[next].get());
        vbo->draw(GL_TRIANGLES, 0, 6);
        GLFramebuffer::popFramebuffer();
        source->unbind();
        layer.current = next;
        source = layer.textures[next].get();
    }
    ShaderManager::instance()->popShader();
}

// Runs the liquid in a Liquid Glass window on to this frame, and draws its surface into data.wavesTexture.
// Returns how much of it to show (1 while it moves, less as it settles; 0: nothing drawn yet), or nothing
// once it's calm.
std::optional<double> LiquidGlassEffect::runLiquid(BlurEffectData &data, const LiquidGlassClient *client, const RectF &glass, const BorderRadius &corners, const Rect &background, GLVertexBuffer *vbo)
{
    // a window whose client asked for the liquid (Stir()) gets the busy pushes; every Liquid Glass surface the
    // clicks' presses, and the sloshing as it moves or grows (a popup sliding up, the panel docking)
    const bool busy = client && client->busy;
    const double momentum = m_liquid.momentum;
    // it renders into float textures: desktop OpenGL
    if (!m_fluidPass.shader || !m_surfacePass.shader || EglContext::currentContext()->isOpenGLES() || glass.isEmpty()) {
        return std::nullopt;
    }
    const bool fresh = !data.fluid;
    if (fresh) {
        data.fluid = std::make_unique<LiquidGlassFluid>();
    }
    LiquidGlassFluid &f = *data.fluid;
    const double now = std::max(m_frameTime, f.time);
    if (fresh) {
        f.time = now;
        f.born = now;
    }
    // where the glass is now, for the followers to take up
    LiquidGlassFollower *const followers[] = {&f.x, &f.y, &f.width, &f.height};
    const double measured[] = {glass.x(), glass.y(), glass.width(), glass.height()};
    bool moving = false;
    for (int i = 0; i < 4; ++i) {
        if (fresh) {
            followers[i]->x = measured[i];
        }
        followers[i]->target = measured[i];
        moving = moving || std::abs(followers[i]->x - followers[i]->target) > 0.05 || std::abs(followers[i]->v) > 0.5;
    }
    const double settle = liquidSettleTime(glass);
    if (busy || f.pushStart >= 0) {
        f.liveUntil = std::max(f.liveUntil, now + settle);
    }
    // A click presses on the liquid where it landed while the button is held, easing in and out over the time
    // a wave as wide as the press takes to pass: a dimple under the pointer that rings out as it's pressed,
    // and again as it's let go. The waves run on until they've settled.
    const double clickIn = std::clamp(m_liquid.clickWidth / (0.38 * m_liquid.speed), 0.04, 0.5);
    if (data.click.down >= 0) {
        const double pressed = data.click.up >= 0 ? data.click.up + clickIn : now;
        f.liveUntil = std::max(f.liveUntil, std::max(pressed, now) + settle);
        if (data.click.up >= 0 && f.time > data.click.up + clickIn) {
            data.click.down = -1; // let go: the press is over
        }
    }
    if (moving && momentum > 0) {
        // the swell settles as fast as it's damped; a move only stirs the ripples a little, so they're out of
        // sight sooner than after a push
        f.liveUntil = std::max(f.liveUntil, now + std::min(std::max(3 * m_liquid.sloshDamping, 0.4 * settle), 15.0));
    }
    if (now >= f.liveUntil) {
        // calm: let go of the layers until something stirs it again
        f.ripples = LiquidGlassLayer();
        f.swell = LiquidGlassLayer();
        for (LiquidGlassFollower *follower : followers) {
            follower->x = follower->target;
            follower->v = 0;
        }
        f.breeze = 0;
        f.ripplesAccel = QVector2D();
        f.swellAccel = QVector2D();
        f.time = now;
        return std::nullopt;
    }

    const double span = std::min(now - f.time, 0.1); // after a stall, carry on from now
    const double start = now - span;
    const double omega = 2 * M_PI * s_liquidFollow;
    const QVector4D cornerRadii = corners.toVector();
    QMatrix4x4 projection;
    projection.ortho(QRectF(0.0, 0.0, background.width(), background.height()));

    // The busy push: while the client is busy, a stretch of one side pushes in (over the time a wave as
    // wide as [Ripple] width takes to pass) and eases back out over the rest of the interval, as far as it
    // came in; or, pressing, a press on the surface there, let go once it's in. Jitter: no two alike.
    const auto startPush = [&](double t) {
        ++f.pushes;
        const auto jit = [&](int k) {
            return m_liquid.jitter * (hash01(f.pushes * 4 + k) - 0.5);
        };
        f.pushStart = t;
        f.pushInterval = m_liquid.interval * (1 + jit(0));
        const double width = m_liquid.width * (1 + 0.8 * jit(1));
        f.pushIn = std::clamp(width / (0.38 * m_liquid.speed), 0.04, 0.8 * f.pushInterval);
        const double strength = std::max(0.0, 1 + 1.2 * jit(2));
        f.pushSide = client->side;
        const double length = f.pushSide < 2 ? glass.height() : glass.width();
        f.pushAt = std::clamp((client->at >= 0 ? client->at : length / 3) + 0.4 * length * jit(3), 1.0, std::max(1.0, length - 1));
        const double c2 = m_liquid.speed * m_liquid.speed;
        // pushing in at this speed at its fastest makes a wave whose steepest slope is s_pushSlope (in a
        // straight channel; it spreads and loses some on its way across); pressing down by about the wave's
        // width does about as much
        f.pushStrength = strength * (m_liquid.press ? 0.8 * c2 * width : s_pushSlope * c2 * f.pushIn / M_PI);
    };
    const auto pushAt = [&](double t, QVector4D *push, QVector4D *press) {
        if (f.pushStart >= 0 && t >= f.pushStart + f.pushInterval) {
            const double next = f.pushStart + f.pushInterval;
            f.pushStart = -1;
            if (busy) {
                startPush(next); // on the beat
            }
        }
        if (f.pushStart < 0 && busy) {
            startPush(t);
        }
        *push = QVector4D(-1, 0, 0, 0);
        *press = QVector4D(0, 0, 1, 0);
        if (f.pushStart < 0) {
            return;
        }
        const double tc = t - f.pushStart;
        if (m_liquid.press) {
            const double radius = m_liquid.width;
            const double inset = radius + 6;
            const QPointF centres[] = {{inset, f.pushAt}, {glass.width() - inset, f.pushAt}, {f.pushAt, inset}, {f.pushAt, glass.height() - inset}};
            const double in = tc < f.pushIn ? std::sin(M_PI * tc / f.pushIn) : 0;
            *press = QVector4D(centres[f.pushSide].x(), centres[f.pushSide].y(), radius, f.pushStrength * in * in);
            return;
        }
        const double rest = f.pushInterval - f.pushIn;
        const double speed = tc < f.pushIn ? f.pushStrength * std::sin(M_PI * tc / f.pushIn)
                                           : -f.pushStrength * f.pushIn / rest * std::sin(M_PI * (tc - f.pushIn) / rest);
        *push = QVector4D(f.pushSide, f.pushAt, m_liquid.strike / 2, speed);
    };

    // the click's press at time t (s): as the busy press, it presses down by about its width at full strength
    const auto clickAt = [&](double t) {
        if (data.click.down < 0 || t < data.click.down) {
            return QVector4D(0, 0, 1, 0);
        }
        const auto ease = [&](double x) {
            const double s = std::sin(0.5 * M_PI * std::clamp(x / clickIn, 0.0, 1.0));
            return s * s;
        };
        double level = ease(t - data.click.down);
        if (data.click.up >= 0) {
            level *= 1 - ease(t - data.click.up);
        }
        // where the pointer was then, between the two samples either side (held at the last one after it)
        const auto &path = data.click.path;
        QPointF at = path.back().second;
        if (t <= path.front().first) {
            at = path.front().second;
        } else {
            for (size_t i = 1; i < path.size(); ++i) {
                if (path[i].first >= t) {
                    const double f = (t - path[i - 1].first) / std::max(path[i].first - path[i - 1].first, 1e-6);
                    at = path[i - 1].second + (path[i].second - path[i - 1].second) * f;
                    break;
                }
            }
        }
        const double pressure = m_liquid.click * 0.8 * m_liquid.speed * m_liquid.speed * m_liquid.clickWidth;
        return QVector4D(at.x(), at.y(), m_liquid.clickWidth, pressure * level);
    };

    // what the glass's moves do over a step from t s into the span: the liquid is pushed against the
    // acceleration of the glass's centre (scaled by gain), so the dropdown unfolding sloshes it too. Each
    // layer feels it smoothed over `smoothing` s: a jolt over that long sends off a wave about as wide as
    // the push's, while one the window takes in steps (a dropdown that unfolds in batches, a pointer's
    // 60 Hz) doesn't shake the liquid in short waves.
    const auto moves = [&](double t, double dt, double gain, QVector2D &felt, double smoothing) {
        const auto change = [&](const LiquidGlassFollower &place, const LiquidGlassFollower &size) {
            double p0, p1, s0, s1;
            followerAt(place, t, omega, &p0);
            followerAt(place, t + dt, omega, &p1);
            followerAt(size, t, omega, &s0);
            followerAt(size, t + dt, omega, &s1);
            return ((p1 - p0) + 0.5 * (s1 - s0)) / dt;
        };
        const QVector2D now(change(f.x, f.width), change(f.y, f.height));
        felt += (now - felt) * float(1 - std::exp(-dt / smoothing));
        m_fluidPass.shader->setUniform(m_fluidPass.accelLocation, -float(gain) * felt);
    };
    // the liquid's edge: in from the rim by as much as it wanders, so it stays inside; and its floor; both
    // shaped their own way for each window
    const double seed = std::fmod(f.born * 0.6180339887, 1.0) * 97;
    // on thin glass (the panel) the shore keeps closer to the rim and the sponge along it is narrower, so
    // waves still run along its middle (both as they were on glass 69 px across and more, as KRunner's)
    const double across = std::min(glass.width(), glass.height());
    const double shoreIn = std::min(m_liquid.shore, 0.12 * across);
    const double rimWidth = std::clamp(0.5 * across - 2, 4.0, s_liquidRim);
    const QVector4D shore(shoreIn, shoreIn, m_liquid.shoreScale, seed);
    const QVector3D bed(m_liquid.floor, m_liquid.floorScale, seed * 1.37 + 5);
    // where the floor is deepest, waves run sqrt(1 + floor) times as fast: the steps get as much shorter
    const double fastest = std::sqrt(1 + m_liquid.floor);
    const auto common = [&]() {
        m_fluidPass.shader->setUniform(m_fluidPass.mvpMatrixLocation, projection);
        m_fluidPass.shader->setUniform(m_fluidPass.glassLocation, QVector2D(glass.width(), glass.height()));
        m_fluidPass.shader->setUniform(m_fluidPass.cornersLocation, cornerRadii);
        m_fluidPass.shader->setUniform(m_fluidPass.shoreLocation, shore);
        m_fluidPass.shader->setUniform(m_fluidPass.bedLocation, bed);
    };
    // the time it takes to push in, which the momentum's waves are smoothed over too
    const double pushTime = std::clamp(m_liquid.width / (0.38 * m_liquid.speed), 0.04, 1.5);

    if (span > 0) {
        // ripples: slow and short, pushed while busy, kept from the rim by the sponge
        const double c = m_liquid.speed;
        const double sponge = 3 * c * -std::log(std::max(m_liquid.reflection, 0.02)) / rimWidth;
        stepLiquid(f.ripples, QSize(int(std::ceil(glass.width() / s_ripplesCell)) + 3, int(std::ceil(glass.height() / s_ripplesCell)) + 3), s_ripplesCell, span,
                   0.5 * s_ripplesCell / (c * fastest), [&](double t, double dt) {
                       common();
                       QVector4D push, press;
                       pushAt(start + t + dt / 2, &push, &press);
                       m_fluidPass.shader->setUniform(m_fluidPass.pushLocation, push);
                       m_fluidPass.shader->setUniform(m_fluidPass.pressLocation, press);
                       m_fluidPass.shader->setUniform(m_fluidPass.clickLocation, clickAt(start + t + dt / 2));
                       moves(t, dt, s_ripplesMomentum * momentum, f.ripplesAccel, pushTime);
                       // gusts about chopScale across, coming and going as fast as a wave crosses half of one,
                       // pressing hard enough that the waves they raise lean the glass a little
                       const double gusts = m_liquid.chopScale;
                       m_fluidPass.shader->setUniform(m_fluidPass.breezeLocation, QVector3D(0.2 * m_liquid.chop * f.breeze * c * c * gusts, gusts, (start + t - f.born) * 0.5 * c / gusts));
                       m_fluidPass.shader->setUniform(m_fluidPass.timingLocation, QVector4D(dt, c * c, 10 * s_ripplesCell * s_ripplesCell / (M_PI * M_PI), s_liquidLevel));
                       m_fluidPass.shader->setUniform(m_fluidPass.dampingLocation, QVector3D(2 / m_liquid.damping, sponge, rimWidth));
                   }, vbo);
        // swell: fast and long, sloshed by the window's moves, every bit of it sent back by the rim
        const double cs = m_liquid.sloshSpeed;
        if (momentum > 0) {
            stepLiquid(f.swell, QSize(int(std::ceil(glass.width() / s_swellCell)) + 3, int(std::ceil(glass.height() / s_swellCell)) + 3), s_swellCell, span,
                       0.5 * s_swellCell / (cs * fastest), [&](double t, double dt) {
                           common();
                           m_fluidPass.shader->setUniform(m_fluidPass.pushLocation, QVector4D(-1, 0, 0, 0));
                           m_fluidPass.shader->setUniform(m_fluidPass.pressLocation, QVector4D(0, 0, 1, 0));
                           m_fluidPass.shader->setUniform(m_fluidPass.clickLocation, QVector4D(0, 0, 1, 0));
                           m_fluidPass.shader->setUniform(m_fluidPass.breezeLocation, QVector3D(0, 1, 0));
                           // its waves at least ~0.15 s long, so broad at its speed
                           moves(t, dt, s_swellMomentum * momentum, f.swellAccel, std::max(0.15, m_liquid.width / (0.38 * cs)));
                           m_fluidPass.shader->setUniform(m_fluidPass.timingLocation, QVector4D(dt, cs * cs, 10 * s_swellCell * s_swellCell / (M_PI * M_PI), s_liquidLevel));
                           m_fluidPass.shader->setUniform(m_fluidPass.dampingLocation, QVector3D(2 / m_liquid.sloshDamping, 0, s_liquidRim));
                       }, vbo);
        } else {
            f.swell = LiquidGlassLayer(); // no momentum: none of it left standing
        }
        for (LiquidGlassFollower *follower : followers) {
            follower->x = followerAt(*follower, span, omega, &follower->v);
        }
        // the breeze rises over about half a second while busy, and dies down over a second after
        f.breeze = busy ? 1 - (1 - f.breeze) * std::exp(-span / 0.5) : f.breeze * std::exp(-span / 1.0);
        f.time = now;
    }
    GLTexture *ripples = f.ripples.textures[f.ripples.current].get();
    GLTexture *swell = f.swell.textures[f.swell.current].get();
    if (!ripples) {
        return 0;
    }

    // the surface, at half size over the background
    const QSize wavesSize((background.width() + 1) / 2, (background.height() + 1) / 2);
    if (!data.wavesTexture || data.wavesTexture->size() != wavesSize) {
        data.wavesFramebuffer.reset();
        data.wavesTexture = GLTexture::allocate(GL_RGBA16F, wavesSize); // slopes go negative
        if (data.wavesTexture) {
            data.wavesTexture->setFilter(GL_LINEAR);
            data.wavesTexture->setWrapMode(GL_CLAMP_TO_EDGE);
            data.wavesFramebuffer = std::make_unique<GLFramebuffer>(data.wavesTexture.get());
        }
    }
    if (!data.wavesFramebuffer || !data.wavesFramebuffer->valid()) {
        return 0;
    }
    ShaderManager::instance()->pushShader(m_surfacePass.shader.get());
    m_surfacePass.shader->setUniform(m_surfacePass.mvpMatrixLocation, projection);
    m_surfacePass.shader->setUniform(m_surfacePass.ripplesLocation, 0);
    m_surfacePass.shader->setUniform(m_surfacePass.swellLocation, 1);
    m_surfacePass.shader->setUniform(m_surfacePass.ripplesCellLocation, float(s_ripplesCell));
    m_surfacePass.shader->setUniform(m_surfacePass.swellCellLocation, float(s_swellCell));
    m_surfacePass.shader->setUniform(m_surfacePass.originLocation, QVector2D(background.x() - glass.x(), background.y() - glass.y()));
    m_surfacePass.shader->setUniform(m_surfacePass.areaLocation, QVector2D(background.width(), background.height()));
    // a fresh wave's crest is about this high (the push's speed over the waves' speed, in a straight channel);
    // and, for Liquid Glass Light's foil, a slosh's from rim to rim of a glass this size (either way) whose
    // slope just leans the glass fully (lean x slope = s_liquidSteep), so the foil lights up as the moves'
    // waves show. On a surface only clicks stir, the crests the press heaps up around it (about a third of how
    // deep it presses at full strength) are the fresh ones, so a click lights the foil whatever the pushes' width.
    const double crest = client ? s_pushSlope * m_liquid.width / (0.38 * M_PI) : 0.3 * 0.8 * m_liquid.clickWidth;
    const double sloshCrest = s_liquidSteep / std::max(m_rippleLean.value_or(m_liquid.amplitude), 0.05) * std::sqrt(glass.width() * glass.height()) / M_PI;
    m_surfacePass.shader->setUniform(m_surfacePass.gainLocation, QVector4D(1, swell ? 1 : 0, crest, sloshCrest));
    glActiveTexture(GL_TEXTURE1);
    (swell ? swell : ripples)->bind();
    glActiveTexture(GL_TEXTURE0);
    ripples->bind();
    GLFramebuffer::pushFramebuffer(data.wavesFramebuffer.get());
    vbo->draw(GL_TRIANGLES, 0, 6);
    GLFramebuffer::popFramebuffer();
    glActiveTexture(GL_TEXTURE1);
    (swell ? swell : ripples)->unbind();
    glActiveTexture(GL_TEXTURE0);
    ripples->unbind();
    ShaderManager::instance()->popShader();

    // over its last 2 s it fades out, so nothing is left standing when it stops
    return smoothStep(0, 2, f.liveUntil - now);
}

void LiquidGlassEffect::blur(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data)
{
    auto it = m_windows.find(w);
    if (it == m_windows.end()) {
        return;
    }

    BlurEffectData &blurInfo = it->second;
    BlurRenderData &renderInfo = blurInfo.render[m_currentView];
    if (!shouldBlur(w, mask, data)) {
        return;
    }

    // Compute the effective blur shape. Note that if the window is transformed, so will be the blur shape.
    RegionF blurShape = blurRegion(w);
    if (data.xScale() != 1 || data.yScale() != 1) {
        blurShape.scale(data.xScale(), data.yScale());
    }
    if (data.xTranslation() || data.yTranslation()) {
        blurShape.translate(data.xTranslation(), data.yTranslation());
    }

    blurShape.translate(w->pos());

    // a Liquid Glass surface shows the blur through its bevel: a Plasma frame (no decoration) whose corners
    // its mask rounds off, or a panel, which docked may have none
    BorderRadius bevelCorners;
    bool liquidGlass = false;
    if ((m_liquidGlass || m_liquidGlassLight) && m_bevelOnscreenPass.shader && w->window()->borderRadius().isNull()) {
        bevelCorners = liquidGlassCorners(blurShape, blurShape.boundingRect());
        liquidGlass = !bevelCorners.isNull() || w->isDock();
    }
    const bool light = liquidGlass && m_liquidGlassLight;
    // and it's frosted more lightly than other blur
    size_t iterationCount = m_iterationCount;
    float offset = m_offset;
    if (liquidGlass) {
        const BlurValuesStruct &frost = blurStrengthValues[std::clamp(light ? m_lightFrost : m_frost, 1, LiquidGlassConfig::blurStrength()) - 1];
        iterationCount = frost.iteration;
        offset = frost.offset;
    }

    const Rect backgroundRect = blurShape.boundingRect().rounded();
    const Rect scaledBackgroundRect = backgroundRect.scaled(viewport.scale()).rounded();
    const Rect deviceBackgroundRect = viewport.mapToDeviceCoordinates(backgroundRect).rounded();
    const auto opacity = w->opacity() * data.opacity();

    // Get the effective shape that will be actually blurred. It's possible that all of it will be clipped.
    QList<RectF> effectiveShape;
    effectiveShape.reserve(blurShape.rects().size());
    if (deviceRegion != Region::infinite()) {
        for (const Rect &clipRect : deviceRegion.rects()) {
            const RectF deviceClipRect = clipRect.translated(-deviceBackgroundRect.topLeft());
            for (const RectF &shapeRect : blurShape.rects()) {
                const RectF deviceShapeRect = shapeRect.translated(-backgroundRect.topLeft()).scaled(viewport.scale()).rounded();
                if (const RectF intersected = deviceClipRect.intersected(deviceShapeRect); !intersected.isEmpty()) {
                    effectiveShape.append(intersected);
                }
            }
        }
    } else {
        for (const RectF &rect : blurShape.rects()) {
            effectiveShape.append(rect.translated(-backgroundRect.topLeft()).scaled(viewport.scale()).rounded());
        }
    }
    if (effectiveShape.isEmpty()) {
        return;
    }

    // Maybe reallocate offscreen render targets. Keep in mind that the first one contains
    // original background behind the window, it's not blurred.
    GLenum textureFormat = GL_RGBA8;
    if (renderTarget.texture()) {
        textureFormat = renderTarget.texture()->internalFormat();
    }

    if (renderInfo.framebuffers.size() != (iterationCount + 1) || renderInfo.textures[0]->size() != backgroundRect.size() || renderInfo.textures[0]->internalFormat() != textureFormat) {
        renderInfo.framebuffers.clear();
        renderInfo.textures.clear();

        glClearColor(0, 0, 0, 0);
        for (size_t i = 0; i <= iterationCount; ++i) {
            auto texture = GLTexture::allocate(textureFormat, backgroundRect.size() / (1 << i));
            if (!texture) {
                qCWarning(KWIN_BLUR) << "Failed to allocate an offscreen texture";
                return;
            }
            texture->setFilter(GL_LINEAR);
            texture->setWrapMode(GL_CLAMP_TO_EDGE);

            auto framebuffer = std::make_unique<GLFramebuffer>(texture.get());
            if (!framebuffer->valid()) {
                qCWarning(KWIN_BLUR) << "Failed to create an offscreen framebuffer";
                return;
            }
            EglContext::currentContext()->pushFramebuffer(framebuffer.get());
            glClear(GL_COLOR_BUFFER_BIT);
            EglContext::currentContext()->popFramebuffer();
            renderInfo.textures.push_back(std::move(texture));
            renderInfo.framebuffers.push_back(std::move(framebuffer));
        }
    }

    // Fetch the pixels behind the shape that is going to be blurred.
    const Region dirtyRegion = viewport.mapFromDeviceCoordinatesContained(deviceRegion) & backgroundRect;
    for (const Rect &dirtyRect : dirtyRegion.rects()) {
        renderInfo.framebuffers[0]->blitFromRenderTarget(renderTarget, viewport, dirtyRect, dirtyRect.translated(-backgroundRect.topLeft()));
    }

    // Upload the geometry: the first 6 vertices are used when downsampling and upsampling offscreen,
    // the remaining vertices are used when rendering on the screen.
    GLVertexBuffer *vbo = GLVertexBuffer::streamingBuffer();
    vbo->reset();
    vbo->setAttribLayout(std::span(GLVertexBuffer::GLVertex2DLayout), sizeof(GLVertex2D));

    const int vertexCount = effectiveShape.size() * 6;
    if (auto result = vbo->map<GLVertex2D>(6 + vertexCount)) {
        auto map = *result;

        size_t vboIndex = 0;

        // The geometry that will be blurred offscreen, in logical pixels.
        {
            const RectF localRect = RectF(0, 0, backgroundRect.width(), backgroundRect.height());

            const float x0 = localRect.left();
            const float y0 = localRect.top();
            const float x1 = localRect.right();
            const float y1 = localRect.bottom();

            const float u0 = x0 / backgroundRect.width();
            const float v0 = 1.0f - y0 / backgroundRect.height();
            const float u1 = x1 / backgroundRect.width();
            const float v1 = 1.0f - y1 / backgroundRect.height();

            // first triangle
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x0, y0),
                .texcoord = QVector2D(u0, v0),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x1, y1),
                .texcoord = QVector2D(u1, v1),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x0, y1),
                .texcoord = QVector2D(u0, v1),
            };

            // second triangle
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x0, y0),
                .texcoord = QVector2D(u0, v0),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x1, y0),
                .texcoord = QVector2D(u1, v0),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x1, y1),
                .texcoord = QVector2D(u1, v1),
            };
        }

        // The geometry that will be painted on screen, in device pixels.
        for (const RectF &rect : effectiveShape) {
            const float x0 = rect.left();
            const float y0 = rect.top();
            const float x1 = rect.right();
            const float y1 = rect.bottom();

            const float u0 = x0 / scaledBackgroundRect.width();
            const float v0 = 1.0f - y0 / scaledBackgroundRect.height();
            const float u1 = x1 / scaledBackgroundRect.width();
            const float v1 = 1.0f - y1 / scaledBackgroundRect.height();

            // first triangle
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x0, y0),
                .texcoord = QVector2D(u0, v0),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x1, y1),
                .texcoord = QVector2D(u1, v1),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x0, y1),
                .texcoord = QVector2D(u0, v1),
            };

            // second triangle
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x0, y0),
                .texcoord = QVector2D(u0, v0),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x1, y0),
                .texcoord = QVector2D(u1, v0),
            };
            map[vboIndex++] = GLVertex2D{
                .position = QVector2D(x1, y1),
                .texcoord = QVector2D(u1, v1),
            };
        }

        vbo->unmap();
    } else {
        qCWarning(KWIN_BLUR) << "Failed to map vertex buffer";
        return;
    }

    vbo->bindArrays();

    // The liquid in a Liquid Glass surface whose client asked for it (Stir()), or that a click presses on: its surface's slope and the
    // ripples' height over the background, at half size, for the bevel pass to lean and clear the glass by
    // (what it multiplies them by; 0: still), and how far their colours part (device px, where a wave leans
    // the glass fully)
    QVector2D ripple;
    float rippleDispersion = 0;
    if (liquidGlass) {
        const auto client = m_liquidGlassClients.find(w->pid());
        const LiquidGlassClient *asked = client != m_liquidGlassClients.end() ? &client->second : nullptr;
        {
            const double lean = m_rippleLean.value_or(m_liquid.amplitude);
            if (lean > 0) {
                if (const std::optional<double> shown = runLiquid(blurInfo, asked, blurShape.boundingRect(), bevelCorners, backgroundRect, vbo)) {
                    if (*shown > 0) {
                        ripple = QVector2D(lean / s_liquidSteep, lean) * *shown;
                        rippleDispersion = m_rippleDispersion.value_or(m_liquid.aberration);
                    }
                    w->addRepaintFull(); // it moves on, whether or not the window draws anything new
                }
            }
        }
    }

    // Liquid Glass Light: the waves go beneath the frost. The background, bent by them and lit in shards of
    // colour where they crest, is what the blur's passes frost (and what its bevel shows sharp), and they
    // don't lean the glass on top.
    GLTexture *frostSource = renderInfo.textures[0].get();
    if (light && ripple.x() > 0 && m_underlayPass.shader) {
        const QSize underlaySize = renderInfo.textures[0]->size();
        if (!blurInfo.underlayTexture || blurInfo.underlayTexture->size() != underlaySize || blurInfo.underlayTexture->internalFormat() != textureFormat) {
            blurInfo.underlayFramebuffer.reset();
            blurInfo.underlayTexture = GLTexture::allocate(textureFormat, underlaySize);
            if (blurInfo.underlayTexture) {
                blurInfo.underlayTexture->setFilter(GL_LINEAR);
                blurInfo.underlayTexture->setWrapMode(GL_CLAMP_TO_EDGE);
                blurInfo.underlayFramebuffer = std::make_unique<GLFramebuffer>(blurInfo.underlayTexture.get());
            }
        }
        if (blurInfo.underlayFramebuffer && blurInfo.underlayFramebuffer->valid()) {
            const RectF window = w->frameGeometry();
            ShaderManager::instance()->pushShader(m_underlayPass.shader.get());

            QMatrix4x4 projectionMatrix;
            projectionMatrix.ortho(QRectF(0.0, 0.0, backgroundRect.width(), backgroundRect.height()));
            const float scale = viewport.scale();

            m_underlayPass.shader->setUniform(m_underlayPass.mvpMatrixLocation, projectionMatrix);
            m_underlayPass.shader->setUniform(m_underlayPass.sizeLocation, QVector2D(underlaySize.width(), underlaySize.height()));
            m_underlayPass.shader->setUniform(m_underlayPass.originLocation, QVector2D(backgroundRect.x() - window.x(), backgroundRect.y() - window.y()));
            m_underlayPass.shader->setUniform(m_underlayPass.areaLocation, QVector2D(backgroundRect.width(), backgroundRect.height()));
            m_underlayPass.shader->setUniform(m_underlayPass.leanLocation, ripple.x());
            m_underlayPass.shader->setUniform(m_underlayPass.lightLocation, QVector4D(m_lightUnderlay.x() * scale, m_lightUnderlay.y(), m_lightUnderlay.z(), m_lightUnderlay.w()));
            m_underlayPass.shader->setUniform(m_underlayPass.timeLocation, float(std::fmod(monotonicNow(), 1000.0)));
            m_underlayPass.shader->setUniform(m_underlayPass.texUnitLocation, 0);
            m_underlayPass.shader->setUniform(m_underlayPass.wavesUnitLocation, 1);

            glActiveTexture(GL_TEXTURE1);
            blurInfo.wavesTexture->bind();
            glActiveTexture(GL_TEXTURE0);
            renderInfo.textures[0]->bind();

            GLFramebuffer::pushFramebuffer(blurInfo.underlayFramebuffer.get());
            vbo->draw(GL_TRIANGLES, 0, 6);
            GLFramebuffer::popFramebuffer();

            glActiveTexture(GL_TEXTURE1);
            blurInfo.wavesTexture->unbind();
            glActiveTexture(GL_TEXTURE0);

            ShaderManager::instance()->popShader();
            frostSource = blurInfo.underlayTexture.get();
        }
    }
    if (light) {
        ripple = QVector2D();
    }

    // The downsample pass of the dual Kawase algorithm: the background will be scaled down 50% every iteration.
    {
        ShaderManager::instance()->pushShader(m_downsamplePass.shader.get());

        QMatrix4x4 projectionMatrix;
        projectionMatrix.ortho(QRectF(0.0, 0.0, backgroundRect.width(), backgroundRect.height()));

        m_downsamplePass.shader->setUniform(m_downsamplePass.mvpMatrixLocation, projectionMatrix);
        m_downsamplePass.shader->setUniform(m_downsamplePass.offsetLocation, offset);

        for (size_t i = 1; i < renderInfo.framebuffers.size(); ++i) {
            const auto &read = renderInfo.framebuffers[i - 1];
            const auto &draw = renderInfo.framebuffers[i];

            const QVector2D halfpixel(0.5 / read->colorAttachment()->width(),
                                      0.5 / read->colorAttachment()->height());
            m_downsamplePass.shader->setUniform(m_downsamplePass.halfpixelLocation, halfpixel);

            (i == 1 ? frostSource : read->colorAttachment())->bind();

            GLFramebuffer::pushFramebuffer(draw.get());
            vbo->draw(GL_TRIANGLES, 0, 6);
        }

        ShaderManager::instance()->popShader();
    }

    // The upsample pass of the dual Kawase algorithm: the background will be scaled up 200% every iteration.
    {
        ShaderManager::instance()->pushShader(m_upsamplePass.shader.get());

        QMatrix4x4 projectionMatrix;
        projectionMatrix.ortho(QRectF(0.0, 0.0, backgroundRect.width(), backgroundRect.height()));

        m_upsamplePass.shader->setUniform(m_upsamplePass.mvpMatrixLocation, projectionMatrix);
        m_upsamplePass.shader->setUniform(m_upsamplePass.offsetLocation, offset);

        for (size_t i = renderInfo.framebuffers.size() - 1; i > 1; --i) {
            GLFramebuffer::popFramebuffer();
            const auto &read = renderInfo.framebuffers[i];

            const QVector2D halfpixel(0.5 / read->colorAttachment()->width(),
                                      0.5 / read->colorAttachment()->height());
            m_upsamplePass.shader->setUniform(m_upsamplePass.halfpixelLocation, halfpixel);

            read->colorAttachment()->bind();

            vbo->draw(GL_TRIANGLES, 0, 6);
        }

        ShaderManager::instance()->popShader();
    }

    const float modulation = opacity * opacity;

    if (const BorderRadius cornerRadius = w->window()->borderRadius(); !cornerRadius.isNull()) {
        ShaderManager::instance()->pushShader(m_roundedOnscreenPass.shader.get());

        QMatrix4x4 projectionMatrix = viewport.projectionMatrix();
        projectionMatrix.translate(scaledBackgroundRect.x(), scaledBackgroundRect.y());

        GLFramebuffer::popFramebuffer();
        const auto &read = renderInfo.framebuffers[1];

        const QVector2D halfpixel(0.5 / read->colorAttachment()->width(),
                                  0.5 / read->colorAttachment()->height());

        const RectF transformedRect = RectF{
            w->frameGeometry().x() + data.xTranslation(),
            w->frameGeometry().y() + data.yTranslation(),
            w->frameGeometry().width() * data.xScale(),
            w->frameGeometry().height() * data.yScale(),
        };
        const RectF nativeBox = transformedRect
                                    .scaled(viewport.scale())
                                    .rounded()
                                    .translated(-scaledBackgroundRect.topLeft());
        const BorderRadius nativeCornerRadius = cornerRadius.scaled(viewport.scale()).rounded();

        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.mvpMatrixLocation, projectionMatrix);
        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.colorMatrixLocation, m_colorMatrix);
        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.halfpixelLocation, halfpixel);
        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.offsetLocation, offset);
        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.boxLocation, QVector4D(nativeBox.horizontalCenter(), nativeBox.verticalCenter(), nativeBox.width() * 0.5, nativeBox.height() * 0.5));
        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.cornerRadiusLocation, nativeCornerRadius.toVector());
        m_roundedOnscreenPass.shader->setUniform(m_roundedOnscreenPass.opacityLocation, modulation);

        read->colorAttachment()->bind();

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        vbo->draw(GL_TRIANGLES, 6, vertexCount);

        glDisable(GL_BLEND);

        ShaderManager::instance()->popShader();
    } else if (liquidGlass) {
        ShaderManager::instance()->pushShader(m_bevelOnscreenPass.shader.get());

        QMatrix4x4 projectionMatrix = viewport.projectionMatrix();
        projectionMatrix.translate(scaledBackgroundRect.x(), scaledBackgroundRect.y());

        GLFramebuffer::popFramebuffer();
        const auto &read = renderInfo.framebuffers[1];

        const QVector2D halfpixel(0.5 / read->colorAttachment()->width(),
                                  0.5 / read->colorAttachment()->height());
        // the glass is the blur region's bounding box, with its rounded corners
        const QVector2D size(scaledBackgroundRect.width(), scaledBackgroundRect.height());
        const float scale = viewport.scale();
        const RectF glass = blurShape.boundingRect();
        // on thin glass the bevel is narrower (s_liquidGlassThinBevel)
        QVector4D bevel = light ? m_lightBevel : m_bevel;
        if (const qreal thin = s_liquidGlassThinBevel * std::min(glass.width(), glass.height()); bevel.x() > thin) {
            bevel.setY(bevel.y() * thin / bevel.x());
            bevel.setX(thin);
        }
        // Where it meets the screen's edge (a docked panel), the glass runs on past it: the outline is moved
        // out beyond the bevel there, so the bevel only shows along the edges that face the screen
        QVector4D box(size.x() / 2, size.y() / 2, size.x() / 2, size.y() / 2);
        if (const LogicalOutput *output = w->screen()) {
            const RectF screen = output->geometryF();
            const float out = (bevel.x() + 1) * scale;
            const float left = glass.left() <= screen.left() + 0.5 ? out : 0;
            const float top = glass.top() <= screen.top() + 0.5 ? out : 0;
            const float right = glass.right() >= screen.right() - 0.5 ? out : 0;
            const float bottom = glass.bottom() >= screen.bottom() - 0.5 ? out : 0;
            box = QVector4D((size.x() + right - left) / 2, (size.y() + bottom - top) / 2, (size.x() + left + right) / 2, (size.y() + top + bottom) / 2);
        }

        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.mvpMatrixLocation, projectionMatrix);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.colorMatrixLocation, m_colorMatrix);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.halfpixelLocation, halfpixel);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.offsetLocation, offset);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.boxLocation, box);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.cornerRadiusLocation, bevelCorners.scaled(scale).toVector());
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.opacityLocation, modulation);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.sizeLocation, size);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.bevelLocation, QVector4D(bevel.x() * scale, bevel.y() * scale, bevel.z() * scale, bevel.w()));
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.sharpUnitLocation, 1);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.wavesUnitLocation, 2);
        m_bevelOnscreenPass.shader->setUniform(m_bevelOnscreenPass.rippleLocation, QVector3D(ripple.x(), ripple.y(), rippleDispersion * scale));

        // the background as it is, before the blur (on light glass, with the waves in it); the liquid's surface
        glActiveTexture(GL_TEXTURE1);
        frostSource->bind();
        if (ripple.x() > 0) {
            glActiveTexture(GL_TEXTURE2);
            blurInfo.wavesTexture->bind();
        }
        glActiveTexture(GL_TEXTURE0);
        read->colorAttachment()->bind();

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        vbo->draw(GL_TRIANGLES, 6, vertexCount);

        glDisable(GL_BLEND);

        glActiveTexture(GL_TEXTURE1);
        frostSource->unbind();
        if (ripple.x() > 0) {
            glActiveTexture(GL_TEXTURE2);
            blurInfo.wavesTexture->unbind();
        }
        glActiveTexture(GL_TEXTURE0);

        ShaderManager::instance()->popShader();
    } else {
        ShaderManager::instance()->pushShader(m_onscreenPass.shader.get());

        QMatrix4x4 projectionMatrix = viewport.projectionMatrix();
        projectionMatrix.translate(scaledBackgroundRect.x(), scaledBackgroundRect.y());

        GLFramebuffer::popFramebuffer();
        const auto &read = renderInfo.framebuffers[1];

        const QVector2D halfpixel(0.5 / read->colorAttachment()->width(),
                                  0.5 / read->colorAttachment()->height());

        m_onscreenPass.shader->setUniform(m_onscreenPass.mvpMatrixLocation, projectionMatrix);
        m_onscreenPass.shader->setUniform(m_onscreenPass.colorMatrixLocation, m_colorMatrix);
        m_onscreenPass.shader->setUniform(m_onscreenPass.halfpixelLocation, halfpixel);
        m_onscreenPass.shader->setUniform(m_onscreenPass.offsetLocation, offset);

        read->colorAttachment()->bind();

        if (modulation < 1.0) {
            glEnable(GL_BLEND);
            glBlendColor(0, 0, 0, modulation);
            glBlendFunc(GL_CONSTANT_ALPHA, GL_ONE_MINUS_CONSTANT_ALPHA);
        }

        vbo->draw(GL_TRIANGLES, 6, vertexCount);

        if (modulation < 1.0) {
            glDisable(GL_BLEND);
        }

        ShaderManager::instance()->popShader();
    }

    if (m_noiseStrength > 0) {
        // Apply an additive noise onto the blurred image. The noise is useful to mask banding
        // artifacts, which often happens due to the smooth color transitions in the blurred image.

        glEnable(GL_BLEND);
        if (opacity < 1.0) {
            glBlendFunc(GL_CONSTANT_ALPHA, GL_ONE);
        } else {
            glBlendFunc(GL_ONE, GL_ONE);
        }

        if (GLTexture *noiseTexture = ensureNoiseTexture()) {
            ShaderManager::instance()->pushShader(m_noisePass.shader.get());

            QMatrix4x4 projectionMatrix = viewport.projectionMatrix();
            projectionMatrix.translate(scaledBackgroundRect.x(), scaledBackgroundRect.y());

            m_noisePass.shader->setUniform(m_noisePass.mvpMatrixLocation, projectionMatrix);
            m_noisePass.shader->setUniform(m_noisePass.noiseTextureSizeLocation, QVector2D(noiseTexture->width(), noiseTexture->height()));

            noiseTexture->bind();

            vbo->draw(GL_TRIANGLES, 6, vertexCount);

            ShaderManager::instance()->popShader();
        }

        glDisable(GL_BLEND);
    }

    vbo->unbindArrays();
}

bool LiquidGlassEffect::isActive() const
{
    return m_valid && !effects->isScreenLocked();
}

bool LiquidGlassEffect::blocksDirectScanout() const
{
    return false;
}

} // namespace KWin

#include "moc_liquidglass.cpp"
