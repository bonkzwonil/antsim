;;;; render/shaders.lisp — GLSL for the 2D view (§5.1, §5.3).
;;;;
;;;; Three programs, drawn back to front: the ground and pheromone field
;;;; as one full-viewport pass, obstacles as filled polygons, and every
;;;; body as an instanced disc.
;;;;
;;;; The colour decision is §5.3's and it is not arbitrary.  The
;;;; meaningful midpoint of the trail field is `k`, the offset in the
;;;; choice function: below it the ants barely discriminate and above it
;;;; they commit.  So that is where the colour map turns.  A viewer can
;;;; then see *which parts of a trail the ants are actually reading as a
;;;; trail* without consulting a legend, which a sequential ramp cannot
;;;; show at all.

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Ground + pheromone field
;;; --------------------------------------------------------------------

(defparameter *field-vertex-glsl* "#version 450 core
// Fullscreen triangle; the fragment shader maps each pixel back to world
// space itself, so there is no geometry to keep in step with the camera.
out vec2 v_uv;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    v_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
")

(defparameter *field-fragment-glsl* "#version 450 core
in vec2 v_uv;
out vec4 frag;

uniform sampler2D u_field;     // trail concentration, R32F
uniform vec4  u_bounds;        // world rect currently visible: x0 y0 x1 y1
uniform vec2  u_world;         // world size in metres
uniform float u_k;             // choice-function offset: the map's midpoint
uniform float u_cap;           // field ceiling
uniform int   u_blocked_shade; // 1 = darken cells the mask marks blocked

// Ground: a faint grid at 5 cm so motion has a reference frame (5.1),
// and so zoom level is legible without any HUD.
vec3 ground(vec2 w, float mpp) {
    vec3 base = vec3(0.055, 0.060, 0.068);
    vec2 g = abs(fract(w / 0.05) - 0.5);
    float line = min(g.x, g.y);
    // fade the grid out when a cell is smaller than a few pixels, which
    // is what stops it turning into moire when zoomed out
    float fade = clamp(0.05 / (mpp * 40.0), 0.0, 1.0);
    return base + vec3(0.020, 0.022, 0.026) * smoothstep(0.06, 0.0, line) * fade;
}

// Diverging about k, in blue.
//
// The field is the brightest thing on screen and the ants sit on top of
// it, so the two have to be separable at a glance.  The first version
// ramped to warm yellow, which put orange laden returners on a yellow
// road and made the traffic — the thing worth watching — nearly
// invisible.  Blue is the complement of the ant palette, so a laden ant
// reads against a strong trail as clearly as an unladen one does.
//
// The turn is still at k, per 5.3: below it the ants barely discriminate
// and above it they commit, so the colour change marks the concentration
// at which a smear becomes a road.
//
// The upper half runs from k to the field's own ceiling rather than to a
// fixed multiple of k.  It used to saturate at 4k, which was fine while
// the cap was 5k and wrong as soon as it was not: a real route peaks
// several times higher than that, so everything from a thin trail to the
// nest entrance came out the same flat white-blue and the picture lost
// exactly the structure the deposits have.  Tying it to the cap makes the
// ramp span whatever range the field can actually hold.
vec3 trail_color(float c) {
    float t = c / u_k;                       // 1.0 at the threshold
    vec3 below = mix(vec3(0.09, 0.13, 0.18), vec3(0.13, 0.30, 0.42),
                     clamp(t, 0.0, 1.0));
    float hi = max(u_cap - u_k, u_k);        // range above the threshold
    vec3 above = mix(vec3(0.13, 0.30, 0.42), vec3(0.55, 0.86, 1.00),
                     clamp((c - u_k) / hi, 0.0, 1.0));
    return t < 1.0 ? below : above;
}

void main() {
    vec2 w = mix(u_bounds.xy, u_bounds.zw, v_uv);
    float mpp = (u_bounds.z - u_bounds.x) / max(1.0, float(textureSize(u_field, 0).x));
    vec3 c = ground(w, (u_bounds.z - u_bounds.x) / 960.0);

    // outside the arena the world simply stops
    if (w.x < 0.0 || w.y < 0.0 || w.x > u_world.x || w.y > u_world.y) {
        frag = vec4(vec3(0.02, 0.022, 0.025), 1.0);
        return;
    }

    float conc = texture(u_field, w / u_world).r;
    if (conc > 0.001) {
        vec3 tc = trail_color(conc);
        // Two ramps, because one cannot do this job.
        //
        // The first rises steeply to 0.55 by 0.6k, so a faint fresh
        // packet is visible at all.  The second carries the rest of the
        // way to the field's own ceiling.
        //
        // A single steep ramp was the earlier version and it made the
        // field look painted rather than alive: it reached full opacity
        // at 0.6k = 12 while the cap is 100, so seven eighths of the
        // field's range sat off the top of the display.  A busy trail
        // pinned at the cap had to lose 88% of its concentration before
        // one pixel changed -- so evaporation, the only mechanism by
        // which the colony forgets, was invisible precisely while it was
        // doing the most work.
        //
        // The second ramp is square-rooted.  Linear against a cap this
        // far above k spends almost all of its opacity on the few
        // hottest cells and leaves an ordinary working trail looking
        // thin; the root keeps the whole band between k and the ceiling
        // legible, which is the band the ants are actually reading.
        float a = 0.45 * clamp(conc / (0.6 * u_k), 0.0, 1.0)
                + 0.55 * sqrt(clamp((conc - 0.6 * u_k)
                                    / max(1.0, u_cap - 0.6 * u_k),
                                    0.0, 1.0));
        c = mix(c, tc, a);
    }
    frag = vec4(c, 1.0);
}
")

;;; --------------------------------------------------------------------
;;; Obstacles
;;; --------------------------------------------------------------------

(defparameter *poly-vertex-glsl* "#version 450 core
layout(location = 0) in vec2 a_pos;
uniform vec4 u_bounds;
void main() {
    vec2 t = (a_pos - u_bounds.xy) / (u_bounds.zw - u_bounds.xy);
    gl_Position = vec4(t * 2.0 - 1.0, 0.0, 1.0);
}
")

(defparameter *poly-fragment-glsl* "#version 450 core
out vec4 frag;
uniform vec3 u_color;
void main() { frag = vec4(u_color, 1.0); }
")

;;; --------------------------------------------------------------------
;;; Bodies — instanced discs
;;; --------------------------------------------------------------------
;;;
;;; §3.11's disc is the collision primitive, and at M2 it is also the
;;; drawing.  M3 replaces this shader with the articulated vector ant and
;;; changes nothing else: the collision model does not move.

(defparameter *body-vertex-glsl* "#version 450 core
// One quad per body, built from gl_VertexID; instance data comes from an
// SSBO so the simulation can write positions straight into a mapped
// pointer with no GL call in the loop.
struct Body { vec4 xyrk; };            // x, y, radius, kind+state packed
layout(std430, binding = 0) readonly buffer Bodies { Body bodies[]; };

uniform vec4 u_bounds;

out vec2 v_local;                      // -1..1 across the quad
flat out float v_kind;
flat out float v_radius_px;

void main() {
    Body b = bodies[gl_InstanceID];
    vec2 corner = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2) - 1.0;
    v_local = corner;
    v_kind = b.xyrk.w;

    vec2 span = u_bounds.zw - u_bounds.xy;
    // never draw a body smaller than a pixel and a half, or a zoomed-out
    // colony vanishes entirely and the view reads as empty
    float r = b.xyrk.z;
    float min_r = 1.5 * span.x / 960.0;
    r = max(r, min_r);
    v_radius_px = r / span.x * 960.0;

    vec2 p = b.xyrk.xy + corner * r;
    vec2 t = (p - u_bounds.xy) / span;
    gl_Position = vec4(t * 2.0 - 1.0, 0.0, 1.0);
}
")

(defparameter *body-fragment-glsl* "#version 450 core
in vec2 v_local;
flat in float v_kind;
flat in float v_radius_px;
out vec4 frag;

// kinds, matching world/bodies.lisp
// 0 ant  1 corpse  2 food  3 nest  4 nest arrival halo (drawing only)
// ants additionally carry state in the fractional part: .1 outbound,
// .2 at food, .3 returning laden, .4 spent, .5-.9 age ramp

vec3 kind_color(float k) {
    int base = int(floor(k + 0.01));
    float frac = k - float(base);
    if (base == 1) return vec3(0.32, 0.30, 0.30);          // corpse: grey
    // The source needs no separate gauge: its body shrinks as it is
    // eaten, so this disc *is* what is left of the pile — and it is the
    // same circle the ants are queueing against, which is why a source
    // running down also gets harder to feed from.
    if (base == 2) return vec3(0.42, 0.80, 0.34);          // food: green
    if (base == 3) return vec3(0.36, 0.25, 0.15);          // nest: brown
    if (base == 4) return vec3(0.62, 0.46, 0.30);          // arrival halo
    if (base == 5) return vec3(0.95, 0.78, 0.36);          // stock in nest
    if (base == 6) return vec3(0.42, 0.84, 0.34);          // food remaining
    // Spent: too little energy left to set out again.  Checked first
    // because it outranks the behavioural states -- an ant under this
    // line is not going anywhere whatever it is nominally doing, and a
    // nest quietly filling with spent ants is the shape a colony's death
    // actually takes.  Drawn in the one hue nothing else on screen uses.
    // Age ramp, .5 newly emerged to .9 fully mature (§5.1).  Only ants
    // with nothing more urgent to report get here: carrying food,
    // sitting at a source and too spent to leave all keep their own
    // colours below, because those are what the picture is for.  Age is
    // the background variable, so it gets the rest.
    //
    // What it makes legible is the colony's age structure, which is new
    // -- before the brood rules of §3.10 every ant was effectively the
    // same age.  A nest gone pink has just bred hard and cannot forage
    // on it yet; a trail of pale ants is a colony spending its young.
    if (frac > 0.45) {
        float t = clamp((frac - 0.5) / 0.4, 0.0, 1.0);
        return mix(vec3(1.00, 0.70, 0.85), vec3(0.86, 0.88, 0.92), t);
    }
    if (frac > 0.35) return vec3(0.95, 0.25, 0.22);        // spent, starving
    if (frac > 0.25) return vec3(1.00, 0.72, 0.30);        // returning laden
    if (frac > 0.15) return vec3(0.95, 0.90, 0.70);        // at food
    return vec3(0.86, 0.88, 0.92);                         // outbound / in nest
}

void main() {
    float d = length(v_local);
    if (d > 1.0) discard;
    vec3 c = kind_color(v_kind);

    // The nest's arrival radius, drawn as a ring.  It is much larger than
    // the nest disc — an arriving cohort has to fit *around* the entrance,
    // not reach its centre — and leaving it invisible put a boundary in
    // the world that ants plainly reacted to and nothing on screen
    // explained.  Drawing it is the honest fix: the picture should show
    // where the model's edges are.
    // Stock gauges: a filled disc whose *area* is the quantity left, so
    // a source visibly empties instead of staying a full green circle
    // until the instant it is gone (§5.1).
    if (v_kind > 4.5) {
        float aa2 = clamp(1.0 / max(v_radius_px, 1.0), 0.02, 0.9);
        frag = vec4(c, smoothstep(1.0, 1.0 - aa2, d));
        return;
    }

    if (v_kind > 3.5) {
        float ring = smoothstep(0.86, 0.99, d) * (1.0 - smoothstep(0.99, 1.0, d));
        if (ring < 0.02) discard;
        frag = vec4(c, ring * 0.5);
        return;
    }

    // antialias by one pixel of the disc's own radius
    float aa = clamp(1.0 / max(v_radius_px, 1.0), 0.02, 0.9);
    float edge = smoothstep(1.0, 1.0 - aa, d);
    // a slight rim keeps a dense crowd from reading as one blob
    c *= mix(0.72, 1.0, smoothstep(1.0, 0.55, d));
    frag = vec4(c, edge);
}
")
