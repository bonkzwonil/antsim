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
;;; §3.11's disc is the collision primitive, and at M2 it was also the
;;; drawing.  M3 leaves it exactly where it was and adds the articulated
;;; ant *beside* it: this shader still draws every food source, nest,
;;; gauge and ring, and it still draws the ants themselves at the zoom
;;; levels where legs are noise (the lowest LOD tier of §5.2).  The
;;; collision model has not moved and neither has this.

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

;;; --------------------------------------------------------------------
;;; The ant — an articulated vector body (§5.2)
;;; --------------------------------------------------------------------
;;;
;;; One mesh (render/antmesh.lisp), instanced, articulated entirely in the
;;; vertex shader.  There is no per-ant CPU work beyond copying eight
;;; floats into a mapped pointer, and no buffer is rewritten to animate
;;; anything: the gait, the antennal sweep, the swelling crop and the
;;; gaster dip are all functions of those eight floats and two uniforms.
;;;
;;; The instance record is §5.2's, packed as two vec4s:
;;;
;;;     p = (x, y, heading, gait phase)
;;;     q = (radius, state, crop load, deposit flick)
;;;
;;; The one piece of real engineering in here is the stance foot.  Phase
;;; advances with distance walked (ANTS-GAIT), so over the half cycle a
;;; leg spends on the ground its foot can be slid backward through the
;;; body frame by exactly the distance the body slides forward — and a
;;; foot that does that is standing still in the *world*, which is what a
;;; foot does.  Tie the same animation to a clock and every ant moonwalks;
;;; the difference is one divisor, and it is the entire cue.
;;;
;;; The skeleton is spliced in from antmesh.lisp rather than written out
;;; again here, because it is the same skeleton the mesh was built around
;;; and two copies of a skeleton is one copy too many.

(defun glsl-f (x)
  (let ((*read-default-float-format* 'single-float))
    (format nil "~,5f" (float x 1.0f0))))

(defun glsl-vec2 (x y)
  (format nil "vec2(~a, ~a)" (glsl-f x) (glsl-f y)))

(defun ant-glsl-tables ()
  "The anatomy of render/antmesh.lisp, as GLSL constants."
  (flet ((arr (name type items)
           (format nil "const ~a ~a[6] = ~a[6](~{~a~^, ~});~%" type name type items)))
    (concatenate
     'string
     (arr "LEG_HIP" "vec2"
          (mapcar (lambda (l) (glsl-vec2 (first l) (second l))) *legs*))
     (arr "LEG_FOOT" "vec2"
          (mapcar (lambda (l) (glsl-vec2 (third l) (fourth l))) *legs*))
     (arr "LEG_LEN" "vec2"
          (mapcar (lambda (l) (glsl-vec2 (fifth l) (sixth l))) *legs*))
     (arr "LEG_KNEE" "float" (mapcar (lambda (l) (glsl-f (seventh l))) *legs*))
     (arr "LEG_PHASE" "float" (mapcar (lambda (l) (glsl-f (eighth l))) *legs*))
     (format nil "~{const float ~a;~%~}"
             (mapcar (lambda (p)
                       (format nil "~a = ~a" (car p) (glsl-f (cdr p))))
                     `(("PETIOLE_X"    . ,*petiole-x*)
                       ("NECK_X"       . ,*neck-x*)
                       ("MANDIBLE_X"   . ,*mandible-x*)
                       ("GASTER_TIP_X" . ,*gaster-tip-x*)
                       ("LEG_W0"       . ,*leg-width-root*)
                       ("LEG_W1"       . ,*leg-width-tip*)
                       ("ANT_W0"       . ,*antenna-width-root*)
                       ("ANT_W1"       . ,*antenna-width-tip*)
                       ("ANT_BX"       . ,*antenna-base-x*)
                       ("ANT_BY"       . ,*antenna-base-y*)
                       ("ANT_SCAPE"    . ,*antenna-scape*)
                       ("ANT_FUNIC"    . ,*antenna-funic*)
                       ("ANT_A1"       . ,*antenna-angle-1*)
                       ("ANT_A2"       . ,*antenna-angle-2*)
                       ("ANT_SWEEP"    . ,*antenna-sweep*)
                       ("ANT_RATE"     . ,*antenna-rate*)
                       ("ANT_BEND"     . ,*antenna-bend*)
                       ("ANT_PROBE"    . ,*antenna-probe*)))))))

(defun build-ant-vertex-glsl ()
  (concatenate 'string "#version 450 core
layout(location = 0) in vec2  a_pos;    // rest position, in ant radii
layout(location = 1) in vec2  a_uv;     // segment: outward normal.  limb: (t, w)
layout(location = 2) in float a_part;
layout(location = 3) in float a_shade;

struct Ant { vec4 p; vec4 q; };
layout(std430, binding = 1) readonly buffer Ants { Ant ants[]; };

uniform vec4      u_bounds;
uniform vec2      u_world;
uniform sampler2D u_field;
uniform float     u_px_per_m;   // pixels per world metre, for feature floors
uniform float     u_seconds;    // simulated seconds — the only clock in the
                                // renderer, and it comes from the tick, so a
                                // frame is still a pure function of the world
uniform float     u_stride;     // one tripod cycle, in ant radii
uniform float     u_k;          // the field's meaningful scale (5.3)

out vec3 v_col;

" (ant-glsl-tables) "
// Fixed in *world* space, not in the ant's.  A light that turns with the
// ant is a head torch, and a thousand of them turning independently reads
// as flicker rather than as shape.
const vec2 LIGHT = vec2(-0.5145, 0.8575);
const float TAU = 6.28318531;

vec2 rot(vec2 v, float c, float s) { return vec2(v.x*c - v.y*s, v.x*s + v.y*c); }

// What an antenna smells at a point.  Vertex shaders have no implicit
// derivatives, hence textureLod rather than texture.
float sniff(vec2 w) {
    vec2 uv = w / u_world;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return 0.0;
    return textureLod(u_field, uv, 0.0).r;
}

float hash01(uint i) {
    uint x = i * 747796405u + 2891336453u;
    x = ((x >> ((x >> 28) + 4u)) ^ x) * 277803737u;
    uint y = (x >> 22) ^ x;
    return float(y & 0xFFFFu) / 65536.0;
}

// The §5.3 palette, and deliberately the same ramp the disc shader uses:
// an ant must not change colour when it crosses an LOD boundary.
vec3 ant_color(float s) {
    if (s < 0.05) return vec3(0.32, 0.30, 0.30);           // a corpse
    if (s > 0.45) {                                        // the age ramp
        float t = clamp((s - 0.5) / 0.4, 0.0, 1.0);
        return mix(vec3(1.00, 0.70, 0.85), vec3(0.86, 0.88, 0.92), t);
    }
    if (s > 0.35) return vec3(0.95, 0.25, 0.22);           // spent, starving
    if (s > 0.25) return vec3(1.00, 0.72, 0.30);           // returning laden
    if (s > 0.15) return vec3(0.95, 0.90, 0.70);           // at food
    return vec3(0.86, 0.88, 0.92);                         // outbound / resting
}

void main() {
    Ant A        = ants[gl_InstanceID];
    vec2  P      = A.p.xy;
    float head   = A.p.z;
    float phase  = A.p.w;
    float radius = A.q.x;
    float state  = A.q.y;
    float load   = A.q.z;
    float flick  = A.q.w;

    float ca = cos(head), sa = sin(head);
    bool dead = (state < 0.05);
    int part = int(a_part + 0.5);
    vec3 base = ant_color(state);

    // The narrowest a limb may be drawn, in radii.  Below about a pixel
    // and a quarter a leg stops being a line and becomes a dashed hint of
    // one, and the gait — the only thing the legs are there to show —
    // goes with it.  This floor is why the ant survives being zoomed out.
    float minw = 1.25 / max(u_px_per_m * radius, 0.001);

    vec2 lp = a_pos;
    vec2 nrm = vec2(0.0);
    float lit = 1.0;

    bool isleg = (part >= 10 && part <= 15);
    bool isant = (part >= 20 && part <= 21);

    if (isleg || isant) {
        vec2 J0, J1, J2;                 // root, joint, tip
        float w0, w1;

        if (isleg) {
            int li = part - 10;
            vec2 hip  = LEG_HIP[li];
            vec2 rest = LEG_FOOT[li];
            float p = fract(phase + LEG_PHASE[li]);
            float amp = 0.25 * u_stride;
            float along, lift;
            if (p < 0.5) {
                // Stance.  The foot is planted in the world, so in the
                // body frame it slides backward at exactly the rate the
                // body slides forward — which is only true because phase
                // is a distance and not a time.
                along = amp * (1.0 - 4.0 * p);
                lift = 0.0;
            } else {
                // Swing: forward again, and quickly.
                float u = (p - 0.5) * 2.0;
                along = mix(-amp, amp, smoothstep(0.0, 1.0, u));
                lift = sin(3.14159265 * u);
            }
            vec2 foot = rest + vec2(along, 0.0);
            // A raised foot is foreshortened seen from above, and swings
            // a little wide on its way round.  That is the whole of the
            // third dimension in this renderer, and it is enough.
            foot = hip + (foot - hip) * (1.0 - 0.10 * lift);
            foot.y += sign(rest.y) * 0.07 * lift;
            if (dead) foot = hip + (rest - hip) * 0.42;   // curled under

            float f = LEG_LEN[li].x, t = LEG_LEN[li].y;
            vec2 d = foot - hip;
            float dl = clamp(length(d), abs(f - t) + 0.02, f + t - 0.02);
            vec2 dir = normalize(d + vec2(1e-6, 0.0));
            float aa = (dl*dl + f*f - t*t) / (2.0 * dl);
            float hh = sqrt(max(0.0, f*f - aa*aa));
            J0 = hip;
            J1 = hip + dir*aa + vec2(-dir.y, dir.x) * hh * LEG_KNEE[li];
            J2 = hip + dir*dl;
            w0 = LEG_W0; w1 = LEG_W1;
            lit = mix(1.0, 1.22, lift);
        } else {
            float side = (part == 20) ? 1.0 : -1.0;
            vec2 b = vec2(ANT_BX, ANT_BY * side);
            // The sweep is the one thing on this ant driven by the clock
            // rather than by the walk, and it has to be: an ant standing
            // still in the nest still waves its antennae.  Offset per ant
            // so that a resting cluster does not beat in unison.
            float sw = dead ? -0.55
                            : sin(TAU * (u_seconds * ANT_RATE
                                         + hash01(uint(gl_InstanceID)))
                                  + (side > 0.0 ? 0.0 : 3.14159265));
            float t1 = side * (ANT_A1 + ANT_SWEEP * sw);
            float t2 = t1 + side * (ANT_A2 + 0.6 * ANT_SWEEP * sw);
            vec2 e0 = b + ANT_SCAPE * vec2(cos(t1), sin(t1));
            vec2 p0 = e0 + ANT_FUNIC * vec2(cos(t2), sin(t2));

            // ...and then it leans toward what it can smell (3.4, 5.2).
            // Two taps either side of the tip, compared exactly the way
            // the ant's own choice function compares its two sensors, so
            // an antenna is visibly on a trail several ticks before the
            // body has turned onto it.  Two texture reads, no CPU work.
            vec2 outward = rot(vec2(0.0, side), ca, sa);
            vec2 tipw = P + rot(p0 * radius, ca, sa);
            float co = sniff(tipw + outward * ANT_PROBE);
            float ci = sniff(tipw - outward * ANT_PROBE);
            float g = dead ? 0.0 : clamp((co - ci) / (co + ci + u_k), -1.0, 1.0);
            t1 += side * ANT_BEND * g;
            t2 += side * ANT_BEND * g * 1.4;

            J0 = b;
            J1 = b + ANT_SCAPE * vec2(cos(t1), sin(t1));
            J2 = J1 + ANT_FUNIC * vec2(cos(t2), sin(t2));
            w0 = ANT_W0; w1 = ANT_W1;
        }

        float t = a_uv.x, w = a_uv.y;
        vec2 d1 = normalize(J1 - J0 + vec2(1e-6, 0.0));
        vec2 d2 = normalize(J2 - J1 + vec2(1e-6, 0.0));
        vec2 m  = d1 + d2;
        vec2 at = (t <= 1.0) ? mix(J0, J1, t) : mix(J1, J2, t - 1.0);
        // Mitred at the joint, so a leg bent double gets an elbow rather
        // than a notch.  Folded flat the mitre is undefined, and there
        // the perpendicular is as good an answer as any.
        vec2 dd = (t < 1.0) ? d1
                : ((t > 1.0) ? d2
                : (length(m) > 0.1 ? normalize(m) : vec2(-d1.y, d1.x)));
        float th = max(mix(w0, w1, t * 0.5), minw);
        vec2 n = vec2(-dd.y, dd.x);
        lp = at + n * w * th;
        nrm = n * w;
    } else {
        nrm = a_uv;
        if (part == 0) {
            // The gaster hangs off the petiole, and three things move it.
            vec2 piv = vec2(PETIOLE_X, 0.0);
            float yaw = dead ? 0.0 : 0.085 * sin(TAU * phase);
            float c2 = cos(yaw), s2 = sin(yaw);
            lp = piv + rot(lp - piv, c2, s2);
            nrm = rot(nrm, c2, s2);
            // A full crop is *inside* the ant (3.5) — Lasius carries
            // liquid, not crumbs — and a distended gaster is what that
            // looks like from above.  The bead at the mandibles below is
            // 5.2's cue; this is the honest one, and having both means a
            // laden ant is legible at every zoom.
            lp = piv + (lp - piv) * vec2(1.0 + 0.12*load, 1.0 + 0.20*load);
            // ...and it tips down at the instant a packet goes into the
            // ground, which seen from above is a foreshortening toward
            // the petiole.  A visible event marking an invisible
            // mechanism, which is the only reason it is here.
            lp = piv + (lp - piv) * vec2(1.0 - 0.34*flick, 1.0 + 0.12*flick);
        } else if (part == 3 || part == 4) {
            // Head and mandibles counter-yaw against the gaster, on the
            // same cycle.  Real ants do this; more to the point, a rigid
            // body with moving legs reads as a toy being dragged.
            vec2 piv = vec2(NECK_X, 0.0);
            float yaw = dead ? 0.0 : -0.06 * sin(TAU * phase);
            float c2 = cos(yaw), s2 = sin(yaw);
            lp = piv + rot(lp - piv, c2, s2);
            nrm = rot(nrm, c2, s2);
        } else if (part == 5) {
            // The carried payload, sized by the load and collapsed to a
            // point when there is none — a degenerate fan costs no
            // fragments, so an unladen ant pays nothing to carry it.
            float r = (load > 0.002) ? 0.23 * (0.45 + 0.55 * load) : 0.0;
            lp = vec2(MANDIBLE_X, 0.0) + a_pos * r;
        } else if (part == 6) {
            // The packet, drawn where it went: at the gaster tip, and
            // *following* the dip rather than sitting at the tip's rest
            // position, or the mark detaches from the ant that made it at
            // exactly the moment it is supposed to explain.
            vec2 piv = vec2(PETIOLE_X, 0.0);
            float yaw = 0.085 * sin(TAU * phase);
            vec2 tip = piv + rot(vec2(GASTER_TIP_X - PETIOLE_X, 0.0),
                                 cos(yaw), sin(yaw)) * (1.0 - 0.34*flick);
            lp = tip + a_pos * (0.20 * flick);
        }
    }

    vec3 col;
    if      (part == 0) col = base * 0.94;
    else if (part == 1) col = base * 0.66;              // petiole, in shadow
    else if (part == 2) col = base * 1.00;
    else if (part == 3) col = base * 0.97;
    else if (part == 4) col = base * 0.52;              // mandibles
    else if (part == 5) col = vec3(0.42, 0.80, 0.34);   // cargo, food green
    else if (part == 6) col = vec3(0.55, 0.86, 1.00);   // the mark, trail blue
    else                col = base * 0.58;              // legs and antennae

    // Rounded, glossy chitin for the price of one dot product: the rim
    // normal turned into world space and lit, the fan centre — whose
    // normal is zero — left flat.
    vec2 nw = rot(nrm, ca, sa);
    float lam = max(0.0, dot(nw, LIGHT));
    float sh = mix(0.90, 0.58 + 0.66 * lam, min(1.0, length(nrm)));
    v_col = col * a_shade * sh * lit;

    vec2 world = P + rot(lp * radius, ca, sa);
    vec2 span = u_bounds.zw - u_bounds.xy;
    vec2 tt = (world - u_bounds.xy) / span;
    gl_Position = vec4(tt * 2.0 - 1.0, 0.0, 1.0);
}
"))

(defparameter *ant-vertex-glsl* (build-ant-vertex-glsl))

;;; Opaque, deliberately.  The pieces of an ant overlap — legs under the
;;; body, mandibles over the head — and with alpha they would show through
;;; one another and the silhouette would dissolve.  Edges are antialiased
;;; by the multisampled target instead (render/offscreen.lisp), which is
;;; the right place for it and fixes the obstacle edges at the same time.
(defparameter *ant-fragment-glsl* "#version 450 core
in vec3 v_col;
out vec4 frag;
void main() { frag = vec4(v_col, 1.0); }
")
