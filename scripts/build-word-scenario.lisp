;;;; scripts/build-word-scenario.lisp — spell a word in obstacles.
;;;;
;;;; Emits three scenarios from one font:
;;;;
;;;;   scenarios/antsim.json           1.00 x 0.72 m — the desk-sized one
;;;;   scenarios/antsim-overload.json  the same arena, far too many ants
;;;;   scenarios/antsim-large.json     5.00 x 3.60 m — five times over
;;;;
;;;; The project's own name rendered as solid terrain in the 3x5 bitmap font
;;;; the HUD draws with, with the nest below it and food above, so every
;;;; journey has to thread the lettering.
;;;;
;;;; Generated rather than hand-authored, and from *FONT-3X5* itself rather
;;;; than from a transcription of it, so the scenario cannot drift away from
;;;; the font — and so spelling something else is a one-line change.
;;;;
;;;; Run: make word-scenario
;;;;
;;;; ---------------------------------------------------------------------
;;;; What scaling an arena does and does not mean
;;;;
;;;; Only the *geometry* scales.  The ant does not: it is 2.5 mm and walks
;;;; at 2 cm/s in both files, because it is the same animal, and that is the
;;;; whole reason a bigger arena is a different experiment rather than the
;;;; same picture printed larger.
;;;;
;;;; Two things follow, and both are settings rather than multiplications:
;;;;
;;;;   * A journey five times longer costs five times the energy, and a
;;;;     forager carries a fixed tank.  The outbound leg is the binding one
;;;;     — an ant refills to full at the source (§3.5), so getting home is
;;;;     never the problem; *finding the source in the first place*, by
;;;;     correlated random walk, across three metres, is.
;;;;
;;;;   * A trail five times longer needs about five times the traffic to
;;;;     hold it up, because evaporation runs on a clock and does not care
;;;;     how far away the food is.  Population is therefore set by trail
;;;;     length, not by area — scaling it by area (x25) would be a crowd,
;;;;     scaling it not at all would be a colony that cannot keep a road
;;;;     open.
;;;;
;;;; The numbers below were measured on the scaled arena, not derived; see
;;;; docs/experiments.md.

(require :asdf)
(push #p"./" asdf:*central-registry*)
(asdf:load-system :antsim/render)

(in-package :antsim)

(defparameter *word* "ANTSIM")

;;; Geometry at unit scale.  The word is 6 glyphs of 3 columns with a
;;; 1-column gap between them: 23 columns by 5 rows.  A column is *PIXEL*
;;; metres, which is what sets both how big the letters are and how wide
;;; the gaps an ant has to walk through are — at 3.5 cm a gap is seven
;;; pheromone cells and fourteen ants abreast, so the lettering shapes the
;;; traffic without strangling it.
;;;
;;; Scaled up, the gaps get wider in ants as well as in metres, which is
;;; the one way the large arena is *easier*: at 17.5 cm a doorway is
;;; seventy ants abreast and stops being a bottleneck at all.  That is a
;;; real difference between the two files and not a defect of either.
(defparameter *pixel* 0.035f0)
(defparameter *world-w* 1.00f0)
(defparameter *world-h* 0.72f0)
(defparameter *baseline* 0.30f0)        ; y of the bottom row of the word

(defun glyph (ch)
  (or (cdr (assoc ch *font-3x5*))
      (error "no glyph for ~s in *font-3x5*" ch)))

(defun word-rects (word scale)
  "One rect per lit pixel, as (x0 y0 x1 y1) in world metres.

Rows run top to bottom in the font and y runs up in the world, so row 0
is the *highest* band.  Getting that backwards spells the word upside
down, which is a fine way to notice you did it."
  (let* ((px (* *pixel* scale))
         (world-w (* *world-w* scale))
         (baseline (* *baseline* scale))
         (cols (- (* 4 (length word)) 1))
         (left (/ (- world-w (* cols px)) 2.0f0))
         (out '()))
    (loop for ch across word
          for gi from 0
          do (loop for row in (glyph ch)
                   for r from 0
                   do (loop for c from 0 below 3
                            do (when (char= (char row c) #\#)
                                 (let* ((x0 (+ left (* px (+ (* gi 4) c))))
                                        (y0 (+ baseline (* px (- 4 r))))
                                        (x1 (+ x0 px))
                                        (y1 (+ y0 px)))
                                   (push (list x0 y0 x1 y1) out))))))
    (nreverse out)))

(defun emit (path &key (scale 1.0f0) (start 400) (stock 900.0f0)
                       (capacity 6000) (world-capacity 8000)
                       (food-amount 60000.0f0) (seed 20260816) note)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (let* ((rects (word-rects *word* scale))
           (world-w (* *world-w* scale))
           (world-h (* *world-h* scale)))
      (format s "{~%  \"name\": ~s,~%~%" (pathname-name path))
      (format s "  \"_what\": \"The project's name, spelled in solid terrain in the\",~%")
      (format s "  \"_what2\": \"same 3x5 font the HUD draws with. The nest sits below\",~%")
      (format s "  \"_what3\": \"the word and the food above it, so every trail has to\",~%")
      (format s "  \"_what4\": \"thread the lettering. Generated from the font itself by\",~%")
      (format s "  \"_what5\": \"scripts/build-word-scenario.lisp -- do not hand-edit.\",~%")
      (when note
        (loop for line in note
              for i from 1
              do (format s "  \"_why~d\": \"~a\",~%" i line)))
      (format s "~%")
      (format s "  \"world\": { \"width\": ~,3f, \"height\": ~,3f, \"capacity\": ~d },~%~%"
              world-w world-h world-capacity)
      (format s "  \"obstacles\": [~%")
      (loop for (x0 y0 x1 y1) in rects
            for i from 0
            do (format s "    { \"rect\": { \"x0\": ~,4f, \"y0\": ~,4f, \"x1\": ~,4f, \"y1\": ~,4f } }~:[~;,~]~%"
                       x0 y0 x1 y1 (< i (1- (length rects)))))
      (format s "  ],~%~%")
      (format s "  \"colonies\": [~%")
      (format s "    { \"id\": \"home\",~%")
      (format s "      \"nest\": { \"x\": ~,3f, \"y\": ~,3f, \"r\": ~,3f },~%"
              (* 0.5f0 world-w) (* 0.075f0 scale) (* 0.022f0 scale))
      (format s "      \"capacity\": ~d,~%      \"start\": ~d,~%" capacity start)
      (format s "      \"stock\": ~,1f }~%  ],~%~%" stock)
      ;; Two sources rather than one, left and right of centre, so the
      ;; colony threads the word in two places and the picture has a trail
      ;; through more of the lettering than a single road would give.
      ;;
      ;; The ceiling on AMOUNT is arithmetic rather than taste.
      ;; FOOD-AMOUNT is a single float and an ant withdraws
      ;; *crop-fill-rate* = 0.02 per tick, so once a source holds more
      ;; than about 0.02 * 2^24 ~ 170 000 units the withdrawal is smaller
      ;; than the float's own resolution at that magnitude and rounds
      ;; away entirely.  The first version of this file used 900 000: the
      ;; sources were silently infinite, and every measurement of food
      ;; eaten on this scenario read exactly zero while the colony was
      ;; visibly thriving on it.  A source too large to deplete is also
      ;; too large to account for.
      (format s "  \"food\": [~%")
      (format s "    { \"x\": ~,3f, \"y\": ~,3f, \"r\": ~,3f, \"amount\": ~,1f, \"quality\": 1.0 },~%"
              (* 0.28f0 world-w) (- world-h (* 0.06f0 scale))
              (* 0.030f0 scale) food-amount)
      (format s "    { \"x\": ~,3f, \"y\": ~,3f, \"r\": ~,3f, \"amount\": ~,1f, \"quality\": 1.0 }~%"
              (* 0.72f0 world-w) (- world-h (* 0.06f0 scale))
              (* 0.030f0 scale) food-amount)
      (format s "  ],~%~%")
      ;; The ant, but only when the arena is not the one it was calibrated
      ;; for.  A forager's tank is fixed and *energy-drain-walking* was set
      ;; against a 1 m arena; five times the distance needs five times the
      ;; range or nothing ever reaches the food.  Measured, not assumed —
      ;; at the default the colony ate 8 units in thirty minutes and went
      ;; from 2000 workers to 26 (docs/experiments.md).
      ;;
      ;; Scaled by exactly 1/scale, so a journey costs the same *fraction
      ;; of a tank* as it does in the small arena and the two files are
      ;; the same experiment at two sizes rather than two experiments.
      (unless (= scale 1.0f0)
        (format s "  \"ant\": {~%")
        (format s "    \"_why\": \"A five times longer journey needs five times the range. See the script header.\",~%")
        (format s "    \"energy_drain_walking\": ~,8f,~%" (/ 1.2f-4 scale))
        (format s "    \"energy_drain_resting\": ~,8f~%" (/ 2.0f-5 scale))
        (format s "  },~%~%"))
      (format s "  \"seed\": ~d,~%  \"duration_s\": 3600~%}~%" seed)
      (format t "~&~a: ~d rects, ~d letters, ~,2f x ~,2f m~%"
              path (length rects) (length *word*) world-w world-h))))

(emit #p"scenarios/antsim.json")

;; The same arena, overloaded: a colony far too large for the income its
;; geometry allows.  This is the regime in which how the nest *distributes*
;; scarce food decides whether it lives, and it is the regime every earlier
;; measurement of that question missed -- those runs started small and grew
;; healthily, so the feeding rule could not matter either way.
(emit #p"scenarios/antsim-overload.json"
      :start 1400 :stock 40.0 :seed 4035347294
      :note (list "1400 ants on 40 units of stock: metabolism exceeds income"
                  "from the first tick, so the only question left is how the"
                  "nest shares what little arrives.  At nest_meals_per_tick 0"
                  "-- the old communal sip -- it stabilises, then from about"
                  "T2800 oscillates at stock 0 with an exhausted nest, and"
                  "never recovers.  With meals it does.  Reported from the"
                  "window; the seed is the one it was seen on."))

;;; Five times over.  Population and stock are *not* multiplied by the area
;;; (x25) — see the header: what a colony has to pay for is the length of
;;; the road it keeps open, not the size of the box it is in.  The food
;;; sources are five times wider, which is what keeps the queue at a source
;;; the same fraction of the colony as it is in the small arena.
(emit #p"scenarios/antsim-large.json"
      :scale 5.0f0
      :start 2000
      :stock 4500.0f0
      :capacity 12000
      :world-capacity 20000
      :food-amount 150000.0f0
      :note (list "Five times the small antsim.json in every length."
                  "The ant is NOT scaled -- see the script header. A journey"
                  "five times longer costs five times the energy out of the"
                  "same fixed tank, which is why this file restates the"
                  "forager's range in its `ant` block. At the default it"
                  "starves: 8 units eaten in 30 minutes, 2000 ants to 26."))
