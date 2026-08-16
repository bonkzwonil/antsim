;;;; scripts/build-word-scenario.lisp — spell a word in obstacles.
;;;;
;;;; Emits scenarios/antsim.json: the project's own name rendered as solid
;;;; terrain in the 3x5 bitmap font the HUD draws with, with the nest below
;;;; it and food above, so every journey has to thread the lettering.
;;;;
;;;; Generated rather than hand-authored, and from *FONT-3X5* itself rather
;;;; than from a transcription of it, so the scenario cannot drift away from
;;;; the font — and so spelling something else is a one-line change.
;;;;
;;;; Run: make word-scenario

(require :asdf)
(push #p"./" asdf:*central-registry*)
(asdf:load-system :antsim/render)

(in-package :antsim)

(defparameter *word* "ANTSIM")

;;; Geometry.  The word is 6 glyphs of 3 columns with a 1-column gap
;;; between them: 23 columns by 5 rows.  A column is *PIXEL* metres, which
;;; is what sets both how big the letters are and how wide the gaps an ant
;;; has to walk through are — at 3.5 cm a gap is seven pheromone cells and
;;; fourteen ants abreast, so the lettering shapes the traffic without
;;; strangling it.
(defparameter *pixel* 0.035f0)
(defparameter *world-w* 1.00f0)
(defparameter *world-h* 0.72f0)
(defparameter *baseline* 0.30f0)        ; y of the bottom row of the word

(defun glyph (ch)
  (or (cdr (assoc ch *font-3x5*))
      (error "no glyph for ~s in *font-3x5*" ch)))

(defun word-rects (word)
  "One rect per lit pixel, as (x0 y0 x1 y1) in world metres.

Rows run top to bottom in the font and y runs up in the world, so row 0
is the *highest* band.  Getting that backwards spells the word upside
down, which is a fine way to notice you did it."
  (let* ((cols (- (* 4 (length word)) 1))
         (left (/ (- *world-w* (* cols *pixel*)) 2.0f0))
         (out '()))
    (loop for ch across word
          for gi from 0
          do (loop for row in (glyph ch)
                   for r from 0
                   do (loop for c from 0 below 3
                            do (when (char= (char row c) #\#)
                                 (let* ((x0 (+ left (* *pixel* (+ (* gi 4) c))))
                                        (y0 (+ *baseline* (* *pixel* (- 4 r))))
                                        (x1 (+ x0 *pixel*))
                                        (y1 (+ y0 *pixel*)))
                                   (push (list x0 y0 x1 y1) out))))))
    (nreverse out)))

(defun emit (path)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (let ((rects (word-rects *word*)))
      (format s "{~%  \"name\": \"antsim\",~%~%")
      (format s "  \"_what\": \"The project's name, spelled in solid terrain in the\",~%")
      (format s "  \"_what2\": \"same 3x5 font the HUD draws with. The nest sits below\",~%")
      (format s "  \"_what3\": \"the word and the food above it, so every trail has to\",~%")
      (format s "  \"_what4\": \"thread the lettering. Generated from the font itself by\",~%")
      (format s "  \"_what5\": \"scripts/build-word-scenario.lisp -- do not hand-edit.\",~%~%")
      (format s "  \"world\": { \"width\": ~,3f, \"height\": ~,3f, \"capacity\": 8000 },~%~%"
              *world-w* *world-h*)
      (format s "  \"obstacles\": [~%")
      (loop for (x0 y0 x1 y1) in rects
            for i from 0
            do (format s "    { \"rect\": { \"x0\": ~,4f, \"y0\": ~,4f, \"x1\": ~,4f, \"y1\": ~,4f } }~:[~;,~]~%"
                       x0 y0 x1 y1 (< i (1- (length rects)))))
      (format s "  ],~%~%")
      (format s "  \"colonies\": [~%")
      (format s "    { \"id\": \"home\",~%")
      (format s "      \"nest\": { \"x\": ~,3f, \"y\": 0.075, \"r\": 0.022 },~%"
              (* 0.5f0 *world-w*))
      (format s "      \"capacity\": 6000,~%      \"start\": 400,~%")
      (format s "      \"stock\": 900.0 }~%  ],~%~%")
      ;; Two sources rather than one, left and right of centre, so the
      ;; colony threads the word in two places and the picture has a trail
      ;; through more of the lettering than a single road would give.
      ;;
      ;; 60 000 units each, and the ceiling is arithmetic rather than
      ;; taste.  FOOD-AMOUNT is a single float and an ant withdraws
      ;; *crop-fill-rate* = 0.02 per tick, so once a source holds more
      ;; than about 0.02 * 2^24 ~ 170 000 units the withdrawal is smaller
      ;; than the float's own resolution at that magnitude and rounds
      ;; away entirely.  The first version of this file used 900 000: the
      ;; sources were silently infinite, and every measurement of food
      ;; eaten on this scenario read exactly zero while the colony was
      ;; visibly thriving on it.  A source too large to deplete is also
      ;; too large to account for.
      (format s "  \"food\": [~%")
      (format s "    { \"x\": ~,3f, \"y\": ~,3f, \"r\": 0.030, \"amount\": 60000.0, \"quality\": 1.0 },~%"
              (* 0.28f0 *world-w*) (- *world-h* 0.06f0))
      (format s "    { \"x\": ~,3f, \"y\": ~,3f, \"r\": 0.030, \"amount\": 60000.0, \"quality\": 1.0 }~%"
              (* 0.72f0 *world-w*) (- *world-h* 0.06f0))
      (format s "  ],~%~%")
      (format s "  \"seed\": 20260816,~%  \"duration_s\": 3600~%}~%")
      (format t "~&~a: ~d rects, ~d letters~%" path (length rects) (length *word*)))))

(emit #p"scenarios/antsim.json")
