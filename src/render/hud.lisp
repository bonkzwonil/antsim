;;;; render/hud.lisp — screen-space panels, bars and text (§5.1 overlay).
;;;;
;;;; The overlay layer: a selected ant's state readout, counters, and
;;;; anything else that belongs in pixels rather than in metres.  Kept
;;;; entirely separate from DRAW-WORLD, because the world is drawn through
;;;; a camera and this is not — a HUD that zoomed with the scene would be
;;;; unreadable at both ends of the range.
;;;;
;;;; No font dependency.  A 3x5 bitmap font is embedded below, authored as
;;;; ASCII art so it can actually be read and corrected in the source
;;;; rather than being a wall of hex nobody can check.  It is small, but
;;;; drawn at 2-3 screen pixels per font pixel it is perfectly legible,
;;;; and it costs one integer per glyph.

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; The font
;;; --------------------------------------------------------------------

(defparameter *font-3x5*
  '((#\Space "..." "..." "..." "..." "...")
    (#\0 "###" "#.#" "#.#" "#.#" "###")
    (#\1 ".#." "##." ".#." ".#." "###")
    (#\2 "###" "..#" "###" "#.." "###")
    (#\3 "###" "..#" "###" "..#" "###")
    (#\4 "#.#" "#.#" "###" "..#" "..#")
    (#\5 "###" "#.." "###" "..#" "###")
    (#\6 "###" "#.." "###" "#.#" "###")
    (#\7 "###" "..#" "..#" "..#" "..#")
    (#\8 "###" "#.#" "###" "#.#" "###")
    (#\9 "###" "#.#" "###" "..#" "###")
    (#\A "###" "#.#" "###" "#.#" "#.#")
    (#\B "##." "#.#" "##." "#.#" "##.")
    (#\C "###" "#.." "#.." "#.." "###")
    (#\D "##." "#.#" "#.#" "#.#" "##.")
    (#\E "###" "#.." "###" "#.." "###")
    (#\F "###" "#.." "###" "#.." "#..")
    (#\G "###" "#.." "#.#" "#.#" "###")
    (#\H "#.#" "#.#" "###" "#.#" "#.#")
    (#\I "###" ".#." ".#." ".#." "###")
    (#\J "..#" "..#" "..#" "#.#" "###")
    (#\K "#.#" "#.#" "##." "#.#" "#.#")
    (#\L "#.." "#.." "#.." "#.." "###")
    (#\M "#.#" "###" "###" "#.#" "#.#")
    (#\N "#.#" "###" "###" "###" "#.#")
    (#\O "###" "#.#" "#.#" "#.#" "###")
    (#\P "###" "#.#" "###" "#.." "#..")
    (#\Q "###" "#.#" "#.#" "###" "..#")
    (#\R "###" "#.#" "##." "#.#" "#.#")
    (#\S "###" "#.." "###" "..#" "###")
    (#\T "###" ".#." ".#." ".#." ".#.")
    (#\U "#.#" "#.#" "#.#" "#.#" "###")
    (#\V "#.#" "#.#" "#.#" "#.#" ".#.")
    (#\W "#.#" "#.#" "###" "###" "#.#")
    (#\X "#.#" "#.#" ".#." "#.#" "#.#")
    (#\Y "#.#" "#.#" ".#." ".#." ".#.")
    (#\Z "###" "..#" ".#." "#.." "###")
    (#\. "..." "..." "..." "..." ".#.")
    (#\: "..." ".#." "..." ".#." "...")
    (#\- "..." "..." "###" "..." "...")
    (#\+ "..." ".#." "###" ".#." "...")
    (#\/ "..#" "..#" ".#." "#.." "#..")
    (#\( "..#" ".#." ".#." ".#." "..#")
    (#\) "#.." ".#." ".#." ".#." "#..")
    (#\% "#.#" "..#" ".#." "#.." "#.#")
    (#\? "###" "..#" ".##" "..." ".#.")
    (#\* "#.#" ".#." "###" ".#." "#.#"))
  "A 3x5 bitmap font, authored as ASCII art so it is reviewable.
Lowercase is deliberately absent — HUD text is upcased on the way in,
which is both legible at this size and half the glyphs.")

(defparameter *font-index* nil
  "char-code -> glyph slot, or 0 (space) for anything unmapped.")
(defparameter *font-bits* nil
  "Glyph slot -> 15-bit mask, row-major from the top-left.")

(defun build-font ()
  (let* ((n (length *font-3x5*))
         (idx (make-array 128 :element-type '(unsigned-byte 32)
                              :initial-element 0))
         (bits (make-array n :element-type '(unsigned-byte 32)
                             :initial-element 0)))
    (loop for (ch . rows) in *font-3x5*
          for slot from 0
          do (setf (aref idx (char-code ch)) slot)
             (let ((m 0))
               (loop for row in rows
                     for r from 0
                     do (loop for c from 0 below 3
                              do (when (char= (char row c) #\#)
                                   (setf m (logior m (ash 1 (+ (* r 3) c)))))))
               (setf (aref bits slot) m)))
    (setf *font-index* idx *font-bits* bits)
    (values idx bits)))

(build-font)

;;; --------------------------------------------------------------------
;;; Shaders
;;; --------------------------------------------------------------------

(defparameter *hud-vertex-glsl* "#version 410 core
// One quad per item, in *pixel* coordinates with the origin top-left.
// Each item is 3 vec4s: rect (xy, zw), color (rgba), misc (x: glyph or -1).
uniform samplerBuffer u_items;
uniform vec2 u_viewport;

out vec2 v_uv;
flat out vec4 v_color;
flat out float v_glyph;

void main() {
    int base = gl_InstanceID * 3;
    vec4 rect = texelFetch(u_items, base);
    vec4 color = texelFetch(u_items, base + 1);
    vec4 misc = texelFetch(u_items, base + 2);
    vec2 corner = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2) * 0.5;
    v_uv = corner;
    v_color = color;
    v_glyph = misc.x;

    // pixels, origin top-left, to NDC.  y is flipped once, here.
    vec2 p = rect.xy + corner * rect.zw;
    vec2 ndc = vec2(p.x / u_viewport.x * 2.0 - 1.0,
                    1.0 - p.y / u_viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
")

(defparameter *hud-fragment-glsl* "#version 410 core
in vec2 v_uv;
flat in vec4 v_color;
flat in float v_glyph;
out vec4 frag;

uniform usamplerBuffer u_glyphs;

void main() {
    if (v_glyph < 0.0) {           // solid rectangle
        frag = v_color;
        return;
    }
    int col = int(floor(v_uv.x * 3.0));
    int row = int(floor(v_uv.y * 5.0));
    col = clamp(col, 0, 2);
    row = clamp(row, 0, 4);
    uint m = texelFetch(u_glyphs, int(v_glyph)).r;
    if ((m & (1u << uint(row * 3 + col))) == 0u) discard;
    frag = v_color;
}
")

;;; --------------------------------------------------------------------
;;; The HUD
;;; --------------------------------------------------------------------

(defconstant +hud-capacity+ 4096
  "Maximum quads per frame — a panel plus a few hundred glyphs is far
under this, and running out silently truncates rather than crashing.")

(defstruct (hud (:constructor %make-hud))
  (program 0 :type unsigned-byte)
  (vao 0 :type unsigned-byte)
  (item-buf 0 :type unsigned-byte)
  (item-tex 0 :type unsigned-byte)
  (item-ptr (cffi:null-pointer) :type cffi:foreign-pointer)
  (glyph-buf 0 :type unsigned-byte)
  (glyph-tex 0 :type unsigned-byte)
  (count 0 :type fixnum))

(defun make-hud ()
  (let ((h (%make-hud :program (link-program *hud-vertex-glsl*
                                             *hud-fragment-glsl*)
                      :vao (gl:gen-vertex-array)
                      :item-ptr (cffi:foreign-alloc :float :count (* +hud-capacity+ 12)))))
    (let ((buf (gl:gen-buffer))
          (tex (gl:gen-texture)))
      (gl:bind-buffer :texture-buffer buf)
      (%gl:buffer-data :texture-buffer (* +hud-capacity+ 12 4) (cffi:null-pointer)
                       :dynamic-draw)
      (gl:bind-texture :texture-buffer tex)
      (%gl:tex-buffer :texture-buffer :rgba32f buf)
      (setf (hud-item-buf h) buf (hud-item-tex h) tex))
    ;; the font, uploaded once
    (let ((buf (gl:gen-buffer))
          (tex (gl:gen-texture))
          (n (length *font-bits*)))
      (gl:bind-buffer :texture-buffer buf)
      (cffi:with-foreign-object (tmp :uint32 n)
        (dotimes (i n) (setf (cffi:mem-aref tmp :uint32 i) (aref *font-bits* i)))
        (%gl:buffer-data :texture-buffer (* n 4) tmp :static-draw))
      (gl:bind-texture :texture-buffer tex)
      (%gl:tex-buffer :texture-buffer :r32ui buf)
      (setf (hud-glyph-buf h) buf (hud-glyph-tex h) tex))
    h))

(defun destroy-hud (h)
  (declare (type hud h))
  (gl:delete-program (hud-program h))
  (gl:delete-vertex-arrays (list (hud-vao h)))
  (gl:delete-textures (list (hud-item-tex h) (hud-glyph-tex h)))
  (gl:delete-buffers (list (hud-item-buf h) (hud-glyph-buf h)))
  (unless (cffi:null-pointer-p (hud-item-ptr h))
    (cffi:foreign-free (hud-item-ptr h))
    (setf (hud-item-ptr h) (cffi:null-pointer)))
  (values))

(defun hud-reset (h)
  (declare (type hud h))
  (setf (hud-count h) 0)
  h)

(defun hud-quad (h x y w gh r g b a &optional (glyph -1.0f0))
  "Queue one screen-space quad.  GLYPH < 0 means a solid rectangle."
  (declare (type hud h))
  (when (< (hud-count h) +hud-capacity+)
    (let ((o (* (hud-count h) 12))
          (p (hud-item-ptr h)))
      (setf (cffi:mem-aref p :float (+ o 0)) (float x 1.0f0)
            (cffi:mem-aref p :float (+ o 1)) (float y 1.0f0)
            (cffi:mem-aref p :float (+ o 2)) (float w 1.0f0)
            (cffi:mem-aref p :float (+ o 3)) (float gh 1.0f0)
            (cffi:mem-aref p :float (+ o 4)) (float r 1.0f0)
            (cffi:mem-aref p :float (+ o 5)) (float g 1.0f0)
            (cffi:mem-aref p :float (+ o 6)) (float b 1.0f0)
            (cffi:mem-aref p :float (+ o 7)) (float a 1.0f0)
            (cffi:mem-aref p :float (+ o 8)) (float glyph 1.0f0)
            (cffi:mem-aref p :float (+ o 9)) 0.0f0
            (cffi:mem-aref p :float (+ o 10)) 0.0f0
            (cffi:mem-aref p :float (+ o 11)) 0.0f0)
      (incf (hud-count h))))
  h)

(defun hud-text (h x y string &key (scale 3.0f0) (r 0.92f0) (g 0.94f0)
                                   (b 0.96f0) (a 1.0f0))
  "Draw STRING at pixel (X, Y), upcased.  Returns the x after the text,
so callers can chain runs of different colour on one line."
  (declare (type hud h))
  (let ((cx (float x 1.0f0))
        (gw (* 3.0f0 scale))
        (gh (* 5.0f0 scale))
        (adv (* 4.0f0 scale)))
    (loop for ch across (string-upcase string)
          for code = (char-code ch)
          do (unless (char= ch #\Space)
               (let ((slot (if (< code 128) (aref *font-index* code) 0)))
                 (hud-quad h cx y gw gh r g b a (float slot 1.0f0))))
             (incf cx adv))
    cx))

(defun hud-bar (h x y w gh frac r g b)
  "A labelled quantity as a filled bar.  Reads faster than a number for
anything bounded, which energy and crop both are."
  (declare (type hud h))
  (hud-quad h x y w gh 1.0 1.0 1.0 0.10)
  (hud-quad h x y (* w (max 0.0f0 (min 1.0f0 (float frac 1.0f0)))) gh
            r g b 0.95))

(defun hud-bar-tick (h x y w gh frac r g b)
  "A threshold marked *on* a bar, as a thin upright line at FRAC of its
width.

A bar says how full something is; it cannot say whether that is enough,
because the line it has to clear is usually somewhere else on screen and
often moving.  Energy is the case that matters: an ant is drawn as spent
when it falls below a threshold that itself falls as the colony gets
hungry, so the same bar means different things at different moments.
Reading the level without the line is exactly how a nest full of
exhausted ants was once mistaken for a nest full of ants declining to
leave (§3.5).

Drawn over the fill rather than under it, so a threshold inside the
filled part is still visible."
  (declare (type hud h))
  (let ((fx (+ x (* w (max 0.0f0 (min 1.0f0 (float frac 1.0f0)))))))
    ;; one pixel of dark either side, so the mark reads against both the
    ;; filled and the empty half of the bar
    (hud-quad h (- fx 2.0) (- y 1.0) 4.0 (+ gh 2.0) 0.02 0.02 0.03 0.85)
    (hud-quad h (- fx 1.0) (- y 1.0) 2.0 (+ gh 2.0) r g b 1.0)))

(defun hud-draw (h vw vh)
  "Flush the queued quads.  Screen space, no camera, blended over the
scene."
  (declare (type hud h))
  (when (plusp (hud-count h))
    (gl:bind-buffer :texture-buffer (hud-item-buf h))
    (%gl:buffer-sub-data :texture-buffer 0 (* (hud-count h) 12 4) (hud-item-ptr h))
    (gl:bind-buffer :texture-buffer 0)
    (gl:enable :blend)
    (gl:blend-func :src-alpha :one-minus-src-alpha)
    (gl:use-program (hud-program h))
    (gl:uniformf (gl:get-uniform-location (hud-program h) "u_viewport")
                 (float vw 1.0f0) (float vh 1.0f0))
    (gl:active-texture :texture0)
    (gl:bind-texture :texture-buffer (hud-item-tex h))
    (gl:uniformi (gl:get-uniform-location (hud-program h) "u_items") 0)
    (gl:active-texture :texture1)
    (gl:bind-texture :texture-buffer (hud-glyph-tex h))
    (gl:uniformi (gl:get-uniform-location (hud-program h) "u_glyphs") 1)
    (gl:bind-vertex-array (hud-vao h))
    (%gl:draw-arrays-instanced :triangle-strip 0 4 (hud-count h))
    (gl:bind-vertex-array 0)
    (gl:use-program 0)
    (gl:disable :blend))
  (values))
