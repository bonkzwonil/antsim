;;;; render/gallery.lisp — the headless image gallery (§7, M2).
;;;;
;;;; Renders a known scenario at known times into docs/images/.  Every
;;;; picture in the README comes from here rather than from a screenshot,
;;;; so it can be regenerated after a change and the documentation cannot
;;;; quietly drift away from what the simulation does.
;;;;
;;;; Deterministic: same seed, same frames, byte for byte.

(in-package #:antsim)

(defparameter *gallery-directory* #p"docs/images/")

(defun gallery-world (&key (seed +default-seed+))
  "The scenario the README shows: one colony, one rich source 35 cm away,
one obstacle across part of the route."
  (let* ((w (make-world :width 0.6f0 :height 0.6f0 :capacity 8000 :seed seed))
         (c (add-colony w :name "home" :nest-x 0.30f0 :nest-y 0.08f0
                          :nest-r 0.02f0 :capacity 3000 :stock 500.0f0)))
    (add-food w 0.34f0 0.43f0 0.03f0 25000.0f0 :quality 1.0f0)
    (add-obstacle w '(0.12 0.20 0.30 0.20 0.30 0.235 0.12 0.235))
    (world-seed-population! w c 150)
    (values w c)))

(defun gallery-shot (w name &key (width 640) (height 448)
                                 cx cy span)
  "One frame.  With no CX/CY/SPAN it frames the whole world."
  (let ((path (merge-pathnames (format nil "~a.png" name)
                               (ensure-directories-exist *gallery-directory*))))
    (render-world-png w path :width width :height height
                             :view (if span
                                       (make-view :cx cx :cy cy :span span
                                                  :vw width :vh height)
                                       (view-fit w :vw width :vh height)))
    (format t "~&  ~a~%" (namestring path))
    path))

(defun render-gallery ()
  "Render the README's images.  `make gallery`."
  (multiple-value-bind (w c) (gallery-world)
    (format t "~&rendering gallery into ~a~%" *gallery-directory*)
    ;; Two early frames rather than one, because between them they show
    ;; the thing the later pictures cannot: the trail arriving.
    ;;
    ;; At 5 s the pheromone total is *exactly* zero — no ant has reached
    ;; the food, let alone come back — so this is the choice function
    ;; running with nothing to read, which is precisely the correlated
    ;; random walk of §3.2.  At 40 s a single thread exists and nothing
    ;; else.  By three minutes there is already a proper trail, which is
    ;; why neither of these is taken later.
    (world-run! w 100)
    (gallery-shot w "00-nothing")
    (format t "~&  5 s: pop ~d, trail ~,0f~%"
            (colony-population c) (field-total (colony-field c)))
    (world-run! w 700)
    (gallery-shot w "01-searching")
    (format t "~&  40 s: pop ~d, trail ~,0f~%"
            (colony-population c) (field-total (colony-field c)))
    ;; Established: the road is a road, and it runs in two lanes.
    (world-run! w (- (* 1200 20) 800))
    (gallery-shot w "02-trail")
    (format t "~&  20 min: pop ~d, trail ~,0f~%"
            (colony-population c) (field-total (colony-field c)))
    ;; Detail: the nest, its arrival radius, and the resting cluster.
    (gallery-shot w "03-nest" :width 360 :height 360
                              :cx 0.30f0 :cy 0.10f0 :span 0.22f0)
    ;; Detail: mid-route traffic, outbound pale and laden returners warm.
    (gallery-shot w "04-traffic" :width 360 :height 360
                                 :cx 0.33f0 :cy 0.30f0 :span 0.18f0)
    ;; Thriving: an hour in, with the colony grown into the trail it built.
    (world-run! w (* 1200 40))
    (gallery-shot w "05-thriving")
    (format t "~&  60 min: pop ~d, trail ~,0f, stock ~,0f~%"
            (colony-population c) (field-total (colony-field c))
            (colony-stock c))
    (values)))
