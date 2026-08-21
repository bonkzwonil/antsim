;;;; render/smoke.lisp — the M0 acceptance frame.
;;;;
;;;; M0's definition of done is "a headless context comes up and writes a
;;;; non-black PNG" (README §7).  A `glClear` to a known colour would
;;;; technically satisfy that sentence while proving almost nothing, so
;;;; this draws a real frame instead: a fullscreen triangle through a
;;;; compiled and linked GLSL 450 program, with a uniform, into an FBO,
;;;; read back and encoded.  If any link in that chain is broken the
;;;; picture is wrong in a way the tests can see.
;;;;
;;;; The image is deliberately a *sketch of the simulation* rather than a
;;;; test pattern: a nest, a food source, a pheromone ridge between them,
;;;; and ants drawn as the discs §3.11 says they are for collision
;;;; purposes.  None of it is simulated — every position here is a hash of
;;;; an index, and this file will be deleted when M2 draws the real thing.
;;;; It is a photograph of the milestone, and it makes the frame's
;;;; correctness judgeable by eye rather than only by pixel statistics.

(in-package #:antsim)

(defparameter *smoke-vertex-glsl* "#version 410 core
// Fullscreen triangle from gl_VertexID alone: no vertex buffer, no
// attributes.  v_uv is 0..1 across the visible region and runs past it
// on the two clipped corners, which costs nothing and avoids a quad.
out vec2 v_uv;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    v_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
")

(defparameter *smoke-fragment-glsl* "#version 410 core
in vec2 v_uv;
out vec4 frag;

uniform vec2 u_res;

float hash1(float n) { return fract(sin(n * 127.1) * 43758.5453123); }

// The trail the ants are walking, as a curve across the arena.
float trail_y(float x) { return 0.30 + 0.40 * x + 0.055 * sin(x * 9.0); }

// Distance to a disc, corrected so a disc is round rather than an
// ellipse on a non-square frame.
float disc(vec2 p, vec2 c, float r, float aspect) {
    return length((p - c) * vec2(aspect, 1.0)) - r;
}

void main() {
    float aspect = u_res.x / u_res.y;
    vec2 uv = v_uv;

    // ground
    vec3 c = mix(vec3(0.055, 0.062, 0.070), vec3(0.130, 0.145, 0.140), uv.y);

    // pheromone: a gaussian ridge along the trail, fading out past the
    // nest and the food rather than running off both edges
    float d = (uv.y - trail_y(uv.x)) / 0.030;
    float ends = smoothstep(0.02, 0.10, uv.x) * (1.0 - smoothstep(0.90, 0.99, uv.x));
    c += vec3(0.42, 0.33, 0.09) * exp(-d * d) * ends;

    // ants, strung along the trail with a little scatter
    for (int i = 0; i < 40; ++i) {
        float fi = float(i);
        float x = hash1(fi + 0.5);
        float y = trail_y(x) + (hash1(fi + 21.0) - 0.5) * 0.040;
        float sd = disc(uv, vec2(x, y), 0.0075, aspect);
        c = mix(vec3(0.88, 0.84, 0.72), c, smoothstep(0.0, 0.0035, sd));
    }

    // nest at one end, food at the other
    c = mix(vec3(0.52, 0.34, 0.20), c,
            smoothstep(0.0, 0.004, disc(uv, vec2(0.07, trail_y(0.07)), 0.048, aspect)));
    c = mix(vec3(0.44, 0.72, 0.34), c,
            smoothstep(0.0, 0.004, disc(uv, vec2(0.93, trail_y(0.93)), 0.036, aspect)));

    frag = vec4(c, 1.0);
}
")

(defun draw-smoke-frame (o)
  "Draw the M0 frame into O.  Requires a current GL context.

The program is built and thrown away per call: this runs once per test,
and a renderer that caches programs is M2's problem, not M0's."
  (declare (type offscreen o))
  (let ((prog (link-program *smoke-vertex-glsl* *smoke-fragment-glsl*)))
    (unwind-protect
         (progn
           (bind-offscreen o)
           (gl:disable :depth-test)
           (gl:clear-color 0.0 0.0 0.0 1.0)
           (gl:clear :color-buffer-bit :depth-buffer-bit)
           (gl:use-program prog)
           (gl:uniformf (gl:get-uniform-location prog "u_res")
                        (float (offscreen-width o) 1.0)
                        (float (offscreen-height o) 1.0))
           (gl:bind-vertex-array (offscreen-empty-vao o))
           (gl:draw-arrays :triangles 0 3)
           (gl:bind-vertex-array 0)
           (gl:use-program 0)
           ;; The readback that follows must see finished work.
           (gl:finish))
      (gl:delete-program prog)))
  (values))

(defun render-smoke-png (path &key (width 960) (height 600))
  "Draw the M0 frame and write it to PATH.  Requires a current context;
use M0-SMOKE to get one."
  (with-offscreen (o width height)
    (draw-smoke-frame o)
    (capture-offscreen o path)))

(defun m0-smoke (&key (path #p"out/m0-smoke.png") (width 960) (height 600))
  "M0 end to end: bring up a headless context, report what GL we got,
draw a frame, write a PNG.  This is what `make smoke` runs."
  (with-headless-gl (c :width width :height height)
    (let ((info (gl-info)))
      (unless (getf info :version)
        (error "GL reports no version string.  This is the libGL trap — ~
                see src/render/preload.lisp.  Run under: guix shell nvda@580 -- ..."))
      (format t "~&GL       ~a~@
                 renderer ~a~@
                 vendor   ~a~@
                 GLSL     ~a~%"
              (getf info :version) (getf info :renderer)
              (getf info :vendor) (getf info :glsl))
      (let ((out (render-smoke-png path :width width :height height)))
        (format t "~&wrote ~a (~dx~d)~%" (namestring (truename out)) width height)
        out))))
