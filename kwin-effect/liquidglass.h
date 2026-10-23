/*
    SPDX-FileCopyrightText: 2010 Fredrik Höglund <fredrik@kde.org>
    SPDX-FileCopyrightText: 2018 Alex Nemeth <alex.nemeth329@gmail.com>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#pragma once

#include "effect/effect.h"
#include "opengl/glutils.h"
#include "scene/item.h"

#include <QDBusContext>
#include <QList>

#include <deque>
#include <functional>
#include <optional>
#include <unordered_map>

namespace KWin
{

class BackgroundEffectItem;

struct BlurRenderData
{
    /// Temporary render targets needed for the Dual Kawase algorithm, the first texture
    /// contains not blurred background behind the window, it's cached.
    std::vector<std::unique_ptr<GLTexture>> textures;
    std::vector<std::unique_ptr<GLFramebuffer>> framebuffers;
};

// plasma-glass: the liquid in a Liquid Glass window that asked for one over D-Bus (KRunner, Stir()): shallow
// water simulated on the GPU (shaders/fluid.frag), stirred while the window is busy and sloshing as it
// moves. It runs in two layers, as on real water long waves run faster than short ones: ripples, the short
// waves the busy push makes, and swell, the long ones the window's moves set sloshing.
struct LiquidGlassLayer
{
    std::unique_ptr<GLTexture> textures[2]; // each cell's height and its right and bottom faces' velocity, in turns
    std::unique_ptr<GLFramebuffer> framebuffers[2];
    int current = 0; // which texture holds the state now
};

// a critically damped follower of where the glass is or how big: it smooths the steps a window moves in (a
// pointer's 60 Hz against faster frames), and its speed and acceleration are what the liquid feels
struct LiquidGlassFollower
{
    double x = 0;
    double v = 0;
    double target = 0;
};

struct LiquidGlassFluid
{
    LiquidGlassLayer ripples;
    LiquidGlassLayer swell;
    double time = 0; // s, monotonic: how far it has run
    double liveUntil = 0; // s: until then it runs and the window repaints (anything that stirs it extends this)
    LiquidGlassFollower x, y, width, height; // the glass's place and size, logical px
    // the busy push under way: when it began (s; -1: none), how long until the next (s), how long it takes
    // to push in (s), how fast it pushes in at its fastest (px/s; or how hard it presses), and where
    double pushStart = -1;
    double pushInterval = 0;
    double pushIn = 0;
    double pushStrength = 0;
    int pushSide = 0;
    double pushAt = 0; // px along the side
    quint32 pushes = 0; // how many so far: each one's jitter
    double breeze = 0; // how strong the breeze is now (0..1: it rises while busy, and dies down after)
    double born = 0; // s: when the liquid was poured, which the breeze's gusts count from
    // the glass's acceleration as each layer feels it (px/s^2): smoothed over about the time a wave as wide
    // as [Ripple] width takes to pass, so a quick jolt doesn't shake the liquid in short waves
    QVector2D ripplesAccel;
    QVector2D swellAccel;
};

// what a client asked for: whether its window is busy, and where the pushes land (side 0 left .. 3 bottom,
// px along it; -1: a third of the way)
struct LiquidGlassClient
{
    bool busy = false;
    int side = 0;
    double at = -1;
};

struct BlurEffectData
{
    /// The region that should be blurred behind the window
    std::optional<RegionF> content;

    /// The region that should be blurred behind the frame
    std::optional<RegionF> frame;

    /**
     * The render data per render view, as they can have different
     *  color spaces and even different windows on them
     */
    std::unordered_map<RenderView *, BlurRenderData> render;

    std::unique_ptr<BackgroundEffectItem> blurItem;

    /// plasma-glass: the liquid, and its surface's slope at half size while it moves
    std::unique_ptr<LiquidGlassFluid> fluid;
    std::unique_ptr<GLTexture> wavesTexture;
    std::unique_ptr<GLFramebuffer> wavesFramebuffer;
    /// and on Liquid Glass Light, the background with the waves in it, for the blur to frost
    std::unique_ptr<GLTexture> underlayTexture;
    std::unique_ptr<GLFramebuffer> underlayFramebuffer;
    /// a click pressing on its liquid: when the button went down and when it came up (s, monotonic; -1: not
    /// yet, or no click), and where the pointer has been since (px in the glass, from its top left as it was
    /// pressed, `origin`), and when: the press follows it while held, like a finger drawn through the liquid
    struct
    {
        double down = -1;
        double up = -1;
        QPointF origin;
        std::deque<std::pair<double, QPointF>> path;
    } click;
};

class LiquidGlassEffect : public KWin::Effect, protected QDBusContext
{
    Q_OBJECT

public:
    LiquidGlassEffect();
    ~LiquidGlassEffect() override;

    static bool supported();
    static bool enabledByDefault();

    void reconfigure(ReconfigureFlags flags) override;
    void prePaintScreen(ScreenPrePaintData &data) override;
    void drawWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data) override;

    bool provides(Feature feature) override;
    bool isActive() const override;

    int requestedEffectChainPosition() const override
    {
        return 20;
    }

    bool eventFilter(QObject *watched, QEvent *event) override;

    bool blocksDirectScanout() const override;

public Q_SLOTS:
    void slotWindowAdded(KWin::EffectWindow *w);
    void slotWindowDeleted(KWin::EffectWindow *w);
    void slotViewRemoved(KWin::RenderView *view);
    // plasma-glass: a press on a Liquid Glass surface presses on its liquid until the button comes up
    void slotMouseChanged(const QPointF &pos, const QPointF &oldpos, Qt::MouseButtons buttons, Qt::MouseButtons oldbuttons,
                          Qt::KeyboardModifiers modifiers, Qt::KeyboardModifiers oldmodifiers);
#if KWIN_BUILD_X11
    void slotPropertyNotify(KWin::EffectWindow *w, long atom);
#endif
    void setupDecorationConnections(EffectWindow *w);

    // plasma-glass, on D-Bus as org.kde.KWin.LiquidGlass at /org/kde/KWin/LiquidGlass: the caller's Liquid
    // Glass windows get the liquid, which sloshes as they move; while busy, a stretch of the rim (side 0
    // left .. 3 bottom, peaking at px along it; -1 for a third of the way) pushes into it again and again,
    // and the waves bend what's behind the glass as its bevel does. KRunner calls it as it shows, and as it
    // gets busy or done.
    Q_SCRIPTABLE void Stir(bool busy, int side, double at);
    // the build running (tools/kwin-effect.sh names each one), so a swap can be checked
    Q_SCRIPTABLE QString Build() const;

private:
    void initBlurStrengthValues();
    RegionF blurRegion(EffectWindow *w) const;
    RegionF decorationBlurRegion(const EffectWindow *w) const;
    bool decorationSupportsBlurBehind(const EffectWindow *w) const;
    bool shouldBlur(const EffectWindow *w, int mask, const WindowPaintData &data) const;
    void updateBlurRegion(EffectWindow *w);
    void blur(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data);
    GLTexture *ensureNoiseTexture();
    void updateLiquidGlass();
    std::optional<double> runLiquid(BlurEffectData &data, const LiquidGlassClient *client, const RectF &glass, const BorderRadius &corners, const Rect &background, GLVertexBuffer *vbo);
    void stepLiquid(LiquidGlassLayer &layer, const QSize &cells, double cell, double span, double maxStep, const std::function<void(double t0, double dt)> &uniforms, GLVertexBuffer *vbo);
    double liquidSettleTime(const RectF &glass) const;

private:
    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int colorMatrixLocation;
        int offsetLocation;
        int halfpixelLocation;
    } m_onscreenPass;

    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int colorMatrixLocation;
        int offsetLocation;
        int halfpixelLocation;
        int boxLocation;
        int cornerRadiusLocation;
        int opacityLocation;
    } m_roundedOnscreenPass;

    // plasma-glass: the blur seen through the bevel of a dark Liquid Glass surface
    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int colorMatrixLocation;
        int offsetLocation;
        int halfpixelLocation;
        int boxLocation;
        int cornerRadiusLocation;
        int opacityLocation;
        int sizeLocation;
        int bevelLocation;
        int sharpUnitLocation;
        int wavesUnitLocation;
        int rippleLocation;
    } m_bevelOnscreenPass;
    // the liquid: a step of one layer (shaders/fluid.frag), and its surface (shaders/surface.frag)
    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int glassLocation;
        int cornersLocation;
        int cellLocation;
        int timingLocation;
        int dampingLocation;
        int accelLocation;
        int pushLocation;
        int pressLocation;
        int clickLocation;
        int breezeLocation;
        int shoreLocation;
        int bedLocation;
    } m_fluidPass;
    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int ripplesLocation;
        int swellLocation;
        int ripplesCellLocation;
        int swellCellLocation;
        int originLocation;
        int areaLocation;
        int gainLocation;
    } m_surfacePass;
    // Liquid Glass Light: the waves beneath the frost (shaders/underlay.frag)
    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int sizeLocation;
        int originLocation;
        int areaLocation;
        int leanLocation;
        int lightLocation;
        int timeLocation;
        int texUnitLocation;
        int wavesUnitLocation;
    } m_underlayPass;
    void loadLiquidGlassSettings();
    QString m_plasmarc; // the Plasma style is set in there
    QString m_glassrc; // plasma-glass's own settings (plasma-glass-tune edits them)
    bool m_liquidGlass = false; // it's the dark Liquid Glass
    bool m_liquidGlassLight = false; // it's Liquid Glass Light
    QVector4D m_lightBevel; // Liquid Glass Light's bevel, as m_bevel
    int m_lightFrost; // and frost, as m_frost
    // and its waves beneath the frost: logical px what's behind is seen from further in where one leans
    // fully, how bright the foil's colours are, its shards' size (logical px), how saturated they are
    QVector4D m_lightUnderlay;
    QVector4D m_bevel; // logical px: width, refraction, dispersion; sharpness at the edge
    int m_frost; // its blur strength, at most (as BlurStrength)
    // KWIN_LIQUID_GLASS_RIPPLE: how far the liquid's waves lean the glass, against the bevel's edge (0: not
    // at all), and how far their colours part (logical px each way where a wave leans it fully), over
    // plasma-glassrc's [Ripple] amplitude and aberration
    std::optional<double> m_rippleLean;
    std::optional<double> m_rippleDispersion;
    // the liquid's settings: plasma-glassrc's [Ripple] group (plasma-glass-tune edits it), followed live
    struct
    {
        double speed = 120; // px/s the ripples run at
        double width = 21; // px: half the width of a push's wave
        double interval = 1.2; // s from one push to the next
        double damping = 36; // s the ripples take to fall by e
        double reflection = 0.3; // how much of a ripple the rim sends back
        double amplitude = 1; // how far a fresh wave's steepest slope leans the glass, against the bevel's edge
        double aberration = 3; // px the colours part each way where a wave leans the glass fully
        double strike = 1; // px of the side that moves as one
        double jitter = 0.6; // how much each push differs: when, how hard, how wide, where
        double chop = 0.3; // how hard the breeze blows while busy, raising small waves all over
        double chopScale = 40; // px: how big its gusts are
        double shore = 8; // px the liquid's edge wanders either way, in from the rim (0: it follows the rim)
        double shoreScale = 120; // px: how long its bends are
        double floor = 0.35; // how much deeper or shallower the liquid gets (0..0.8 of the average: 0 flat), so
                             // waves bend as they cross
        double floorScale = 220; // px: how long its swells are
        bool press = false; // the pushes press on the surface beside the side, rather than push the side in
        double momentum = 1; // how much the window's moves slosh the liquid
        double sloshSpeed = 900; // px/s the long waves run at
        double sloshDamping = 1.5; // s the sloshing takes to fall by e
        double click = 1; // how hard a click presses on the liquid of the glass it lands on (0: not at all)
        double clickWidth = 24; // px: how wide the press is (a Gaussian's 1/e radius)
    } m_liquid;
    EffectWindow *m_clickWindow = nullptr; // the window a held click presses on
    std::unordered_map<pid_t, LiquidGlassClient> m_liquidGlassClients;
    double m_frameTime = 0; // s, monotonic: when the frame being painted is due on screen

    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int offsetLocation;
        int halfpixelLocation;
    } m_downsamplePass;

    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int offsetLocation;
        int halfpixelLocation;
    } m_upsamplePass;

    struct
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrixLocation;
        int noiseTextureSizeLocation;

        std::unique_ptr<GLTexture> noiseTexture;
        qreal noiseTextureScale = 1.0;
        int noiseTextureStength = 0;
    } m_noisePass;

    bool m_valid = false;
#if KWIN_BUILD_X11
    long net_wm_blur_region = 0;
#endif
    RenderView *m_currentView = nullptr;

    QMatrix4x4 m_colorMatrix;
    size_t m_iterationCount; // number of times the texture will be downsized to half size
    int m_offset;
    int m_expandSize;
    int m_noiseStrength;

    struct OffsetStruct
    {
        float minOffset;
        float maxOffset;
        int expandSize;
    };

    QList<OffsetStruct> blurOffsets;

    struct BlurValuesStruct
    {
        int iteration;
        float offset;
    };

    QList<BlurValuesStruct> blurStrengthValues;

    QMap<EffectWindow *, QMetaObject::Connection> windowBlurChangedConnections;
    std::unordered_map<EffectWindow *, BlurEffectData> m_windows;
};

inline bool LiquidGlassEffect::provides(Effect::Feature feature)
{
    if (feature == Blur) {
        return true;
    }
    return KWin::Effect::provides(feature);
}

} // namespace KWin
