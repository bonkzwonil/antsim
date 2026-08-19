;;;; scripts/build-icon.lisp — the application icon, drawn rather than kept.
;;;;
;;;; Run it as:  sbcl --script scripts/build-icon.lisp   (or `make icon`)
;;;; Output:     packaging/antsim.png, 256x256 RGBA
;;;;
;;;; The result is committed, because packaging must not need a graphics
;;;; stack; this script is how it is regenerated, and it exists so that the
;;;; icon is a thing with a source rather than a binary somebody once made
;;;; in an image editor and nobody can now change.
;;;;
;;;; It uses the project's own PNG writer and the renderer's own background
;;;; colour, and it uses no OpenGL: every pixel here is computed on the CPU.
;;;; An icon that needed a GPU to exist would be an icon CI could not
;;;; rebuild.
;;;;
;;;; What it draws is the one picture the whole project is about — a trail
;;;; between a nest and a food source, with an ant on it.  Not a logo: the
;;;; §3.8 result, at 256 pixels.

(require :asdf)

(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup) (load setup)))

(push (uiop:pathname-parent-directory-pathname
       (uiop:pathname-directory-pathname *load-truename*))
      asdf:*central-registry*)

(funcall (or (find-symbol (string '#:quickload) '#:ql) #'asdf:load-system)
         :antsim/render)

(in-package #:antsim)

(defconstant +size+ 256)

(defun icon-pixels ()
  (let ((px (make-array (* +size+ +size+ 4) :element-type '(unsigned-byte 8)
                                            :initial-element 0)))
    (labels ((idx (x y) (* 4 (+ x (* y +size+))))
             (put (x y r g b a)
               (when (and (<= 0 x (1- +size+)) (<= 0 y (1- +size+)))
                 (let* ((i (idx x y))
                        ;; Source-over, so the trail glow and the ant can
                        ;; be laid down in passes without either one
                        ;; punching a hole in what is underneath.
                        (sa (/ a 255.0))
                        (da (/ (aref px (+ i 3)) 255.0))
                        (oa (+ sa (* da (- 1.0 sa)))))
                   (when (plusp oa)
                     (flet ((mix (s d) (round (* 255 (/ (+ (* (/ s 255.0) sa)
                                                          (* (/ d 255.0) da
                                                             (- 1.0 sa)))
                                                       oa)))))
                       (setf (aref px i)       (mix r (aref px i))
                             (aref px (+ i 1)) (mix g (aref px (+ i 1)))
                             (aref px (+ i 2)) (mix b (aref px (+ i 2)))
                             (aref px (+ i 3)) (round (* 255 oa))))))))
             (disc (cx cy radius r g b &key (alpha 255) (soft 1.0))
               ;; SOFT is the fraction of the radius spent fading out.  A
               ;; hard disc at this size is a staircase; everything here is
               ;; drawn soft and the antialiasing comes for free.
               (let ((lo (max 0 (floor (- cx radius)))) (hi (min (1- +size+) (ceiling (+ cx radius))))
                     (vlo (max 0 (floor (- cy radius)))) (vhi (min (1- +size+) (ceiling (+ cy radius)))))
                 (loop for y from vlo to vhi do
                   (loop for x from lo to hi do
                     (let* ((d (sqrt (+ (expt (- x cx) 2) (expt (- y cy) 2))))
                            (edge (* radius (- 1.0 soft)))
                            (f (cond ((<= d edge) 1.0)
                                     ((>= d radius) 0.0)
                                     (t (- 1.0 (/ (- d edge) (max 1e-6 (- radius edge))))))))
                       (when (plusp f)
                         (put x y r g b (round (* alpha f f)))))))))
             (ellipse (cx cy rx ry angle r g b &key (alpha 255))
               (let ((ca (cos angle)) (sa (sin angle))
                     (rad (ceiling (max rx ry))))
                 (loop for y from (max 0 (- (floor cy) rad)) to (min (1- +size+) (+ (ceiling cy) rad)) do
                   (loop for x from (max 0 (- (floor cx) rad)) to (min (1- +size+) (+ (ceiling cx) rad)) do
                     (let* ((dx (- x cx)) (dy (- y cy))
                            (u (/ (+ (* dx ca) (* dy sa)) rx))
                            (v (/ (- (* dy ca) (* dx sa)) ry))
                            (d (sqrt (+ (* u u) (* v v)))))
                       ;; A steep ramp rather than a soft one: the body
                       ;; sits on a trail of nearly its own brightness,
                       ;; and a gentle edge there is not softness, it is
                       ;; the ant dissolving into the road.
                       (when (< d 1.0)
                         (put x y r g b (round (* alpha (min 1.0 (* 4.5 (- 1.0 d))))))))))))
             (line (x0 y0 x1 y1 w r g b &key (alpha 255))
               (let ((n (ceiling (* 2 (max (abs (- x1 x0)) (abs (- y1 y0)))))))
                 (loop for i from 0 to n
                       for tt = (/ (float i) (max 1 n))
                       do (disc (+ x0 (* tt (- x1 x0))) (+ y0 (* tt (- y1 y0)))
                                w r g b :alpha alpha :soft 1.0)))))

      ;; Background: the renderer's own clear colour (renderer.lisp), so
      ;; the icon and the window agree about what "the arena" looks like.
      (dotimes (y +size+)
        (dotimes (x +size+)
          (let ((i (idx x y)))
            (setf (aref px i) 5 (aref px (+ i 1)) 6 (aref px (+ i 2)) 6
                  (aref px (+ i 3)) 255))))

      ;; The trail: a curve from nest to food, laid down twice — a wide
      ;; dim pass for the glow a strong trail has in the field, and a
      ;; narrow bright one for the road itself.
      (flet ((trail (w r g b alpha)
               (let ((prev nil))
                 (loop for i from 0 to 96
                       for tt = (/ i 96.0)
                       ;; A shallow S, because a straight line between two
                       ;; discs reads as a diagram and a colony's trail
                       ;; never is one.
                       for x = (+ 52 (* tt 152))
                       for y = (+ 196 (* -140 tt) (* 26 (sin (* pi tt))))
                       do (when prev
                            (line (car prev) (cdr prev) x y w r g b :alpha alpha))
                          (setf prev (cons x y))))))
        (trail 13.0 40 120 70 90)
        (trail 5.5 90 220 130 210))

      ;; Food, top right: the yellow-green the renderer gives a source.
      (disc 204 56 26.0 30 60 30 :alpha 200 :soft 1.0)
      (disc 204 56 17.0 190 220 90 :alpha 255 :soft 0.55)

      ;; Nest, bottom left.
      (disc 52 196 30.0 70 45 25 :alpha 190 :soft 1.0)
      (disc 52 196 19.0 205 150 80 :alpha 255 :soft 0.5)

      ;; The ant, on the trail, walking up it.  Three ellipses and six
      ;; legs — the same articulation the renderer draws (§5.2), by hand
      ;; and much simplified, because at 256 pixels the skeleton is the
      ;; only part of it that survives.
      (let* ((cx 128.0) (cy 122.0)
             (a (- (atan -1.0 1.05)))     ; heading, up and to the right
             (ca (cos a)) (sa (sin a)))
        (flet ((along (u v)                ; body frame -> image frame
                 (cons (+ cx (- (* u ca) (* v sa)))
                       (+ cy (+ (* u sa) (* v ca))))))
          ;; Legs first, so the body sits on top of them.
          (loop for (u . spread) in '((11.0 . 1.15) (1.0 . 1.55) (-8.0 . 1.95))
                do (dolist (side '(-1 1))
                     (let* ((hip (along u (* side 4.0)))
                            (knee (along (+ u (* 7 (cos spread)))
                                         (* side (+ 13 (* 4 (sin spread))))))
                            (foot (along (+ u (* 3 (cos spread)))
                                         (* side 23.0))))
                       (line (car hip) (cdr hip) (car knee) (cdr knee)
                             2.1 200 175 150 :alpha 235)
                       (line (car knee) (cdr knee) (car foot) (cdr foot)
                             1.7 200 175 150 :alpha 235))))
          ;; Antennae.
          (dolist (side '(-1 1))
            (let ((base (along 17.0 (* side 2.0)))
                  (tip (along 31.0 (* side 13.0))))
              (line (car base) (cdr base) (car tip) (cdr tip)
                    1.6 200 175 150 :alpha 220)))
          ;; Head, thorax, gaster — each over a dark shadow a little
          ;; larger than itself.  Without it the pale body and the bright
          ;; trail are the same value and the ant reads as a smudge on the
          ;; road rather than as something standing on it.
          (let ((h (along 16.0 0.0)) (th (along 3.0 0.0)) (g (along -13.0 0.0)))
            (ellipse (car h) (cdr h) 10.0 9.0 a 8 14 10 :alpha 190)
            (ellipse (car th) (cdr th) 11.5 9.5 a 8 14 10 :alpha 190)
            (ellipse (car g) (cdr g) 15.5 12.5 a 8 14 10 :alpha 190)
            (ellipse (car h) (cdr h) 7.5 6.5 a 232 205 178)
            (ellipse (car th) (cdr th) 9.0 7.0 a 224 194 165)
            (ellipse (car g) (cdr g) 13.0 10.0 a 240 214 186)))))
    px))

(let ((out (merge-pathnames "packaging/antsim.png"
                            (uiop:pathname-parent-directory-pathname
                             (uiop:pathname-directory-pathname *load-truename*)))))
  (ensure-directories-exist out)
  ;; FLIP is for glReadPixels' bottom-up frames.  These pixels are already
  ;; top-down, so it must be off, and forgetting is an upside-down ant.
  (write-png out (icon-pixels) +size+ +size+ :channels 4 :flip nil)
  (format t "~&;; build-icon: wrote ~a~%" out))
