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
    (add-food w 0.34f0 0.43f0 0.03f0 2500.0f0 :quality 1.0f0)
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

(defun gallery-traffic-x (w y0 y1)
  "The median x of the ants currently between Y0 and Y1, or NIL if there
are none.

A close crop of a *route* cannot be framed by a constant, because the
route is not in a constant place: the colony lays it wherever its ants
happen to go, so a hand-picked centre is right for exactly one run and
slides quietly off the trail the next time anything in the model
changes.  This asks where the traffic actually is.

The ants and not the field, which was the first version and is subtly
the wrong question.  The strongest *cell* is where the pheromone is, and
pheromone is laid by laden ants coming home — so centring on it frames
the inbound lane and pushes the outbound one off the edge.  The picture
is of the traffic, so the traffic is what it should be centred on.

The median and not the mean, which was the second version and framed an
empty patch of ground the first time the route moved.  Most ants in the
band are on the road, but the few that are not are foragers wandering
anywhere in the arena, and they are not distributed symmetrically about
it — so the mean sits between the trail and whichever side happens to
hold the strays, which at a 4.5 cm span is off the picture entirely.  The
median ignores them by construction: it asks where the *bulk* of the
traffic is, which is the question the crop is actually about.

The same argument as everywhere else in this file, one level up: the
pictures are generated rather than screenshotted so they cannot drift
away from what the simulation does, and where the camera points is part
of the picture."
  (declare (type world w) (type f32 y0 y1))
  (let* ((a (world-ants w))
         (b (world-bodies w))
         (xs (bodies-x b)) (ys (bodies-y b))
         (acc (make-array 64 :element-type 'f32
                             :adjustable t :fill-pointer 0)))
    (dotimes (i (ants-n a))
      (when (ant-live-p a i)
        (let* ((bi (aref (ants-body a) i))
               (y (aref ys bi)))
          (when (<= (min y0 y1) y (max y0 y1))
            (vector-push-extend (aref xs bi) acc)))))
    (let ((n (fill-pointer acc)))
      (when (plusp n)
        (let ((v (sort (make-array n :element-type 'f32
                                     :initial-contents (coerce acc 'list))
                       #'<)))
          (if (oddp n)
              (aref v (floor n 2))
              (* 0.5f0 (+ (aref v (1- (floor n 2))) (aref v (floor n 2))))))))))

(defun gallery-bridge (kind name seed minutes)
  "Render one bridge experiment after it has committed (§3.8).

The apparatus and its protocol are the ones the acceptance rows use — a
fixed colony of the size the experiment is calibrated for, and no death
by old age — because a picture captioned with a published result has to
have been produced by the run that result is asserted from.  Rendering it
under different conditions would make the figure a decoration."
  (let* ((b (ecase kind
              (:binary (binary-bridge :seed seed))
              (:double (double-bridge :seed seed))))
         (w (bridge-world b))
         (c (bridge-colony b)))
    (let ((*brood-investment* 0.0f0)
          (*max-age-ticks* 2000000000)
          ;; Explicitly the shipped default, because RENDER-GALLERY turns
          ;; this on for the foraging pictures and these two frames have to
          ;; be the runs the acceptance rows assert on.
          (*resting-ants-block* nil))
      ;; the same two phases: let it commit, then measure a clean window
      (bridge-run! b (* 1200 (floor minutes 2)))
      (bridge-reset-counts! b)
      (bridge-run! b (* 1200 (ceiling minutes 2))))
    (gallery-shot w name)
    (format t "~&  ~a: share ~{~,3f~^ / ~}, winner arm ~a, pop ~d~%"
            name (bridge-share b) (bridge-winner b) (colony-population c))
    b))

(defun render-gallery ()
  "Render the README's images.  `make gallery`."
  ;; The foraging pictures are rendered with *RESTING-ANTS-BLOCK* on.
  ;; It ships off — passing delivers more food and keeps a departing ant's
  ;; remembered exit bearing honest — but 04-nest is a picture *of* the
  ;; cluster the collision rule packs around the entrance, and with the
  ;; flag at its default there is nothing at the door to photograph.
  ;; Nothing in the model ranks the two (§3.11), so the gallery picks the
  ;; one that shows the mechanism and says so here rather than leaving a
  ;; caption describing something the image does not contain.
  ;;
  ;; GALLERY-BRIDGE rebinds it to the default: those two frames are the
  ;; published experiments and have to match the acceptance protocol.
  (let ((*resting-ants-block* t))
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
      ;; Forming, then established.  Five minutes is where the trail first
      ;; reads as a single road; twenty is where it has split into lanes.
      (world-run! w (- (* 1200 5) 800))
      (gallery-shot w "02-forming")
      (format t "~&  5 min: pop ~d, trail ~,0f~%"
              (colony-population c) (field-total (colony-field c)))
      (world-run! w (* 1200 15))
      (gallery-shot w "03-trail")
      (format t "~&  20 min: pop ~d, trail ~,0f~%"
              (colony-population c) (field-total (colony-field c)))
      ;; Detail: the nest, its arrival radius, and the resting cluster.
      (gallery-shot w "04-nest" :width 360 :height 360
                                :cx 0.30f0 :cy 0.10f0 :span 0.22f0)
      ;; Detail: mid-route traffic, outbound pale and laden returners warm.
      (gallery-shot w "05-traffic" :width 360 :height 360
                                   :cx 0.33f0 :cy 0.30f0 :span 0.18f0)
      ;; Detail: close enough that an ant is an ant (§5.2).  The same
      ;; stretch of trail as the frame above, at the zoom where the level of
      ;; detail hands over to the articulated body — legs, antennae,
      ;; mandibles, a swollen crop on the ants carrying one.
      ;;
      ;; Worth taking from the running scenario rather than from a posed
      ;; specimen, because the two things this milestone is *for* are only
      ;; visible in traffic: every ant is at its own point in its own gait,
      ;; and every ant is pointing where it is actually going.
      ;; Framed on the road rather than at a remembered coordinate: at this
      ;; zoom the crop is 4.5 cm wide and the route wanders further than
      ;; that between runs, so a constant here is a picture that works once.
      (gallery-shot w "15-vector-ant" :width 640 :height 400
                                      :cx (or (gallery-traffic-x w 0.295f0 0.315f0)
                                              0.32f0)
                                      :cy 0.305f0 :span 0.045f0)
      ;; Detail: the obstacle's right-hand end, where the route has to
      ;; squeeze past it.  Nothing in the model knows about bottlenecks;
      ;; this is the non-overlap rule and the deposition rule feeding each
      ;; other, and it is the most interesting picture in the set.
      (gallery-shot w "07-jam" :width 360 :height 360
                               :cx 0.30f0 :cy 0.225f0 :span 0.13f0)
      ;; Detail: the source itself, where arriving ants compete for an edge
      ;; that gets shorter as the pile goes down.
      (gallery-shot w "08-crowd" :width 360 :height 360
                                 :cx 0.34f0 :cy 0.43f0 :span 0.13f0)
      ;; The collapse, in three frames.
      ;;
      ;; This is the §3.8 trail-death row as a picture, and the reason it
      ;; needs three frames rather than a before and an after is that the
      ;; interesting part is in between: the colony goes on *using* a trail
      ;; it is no longer reinforcing.  Ants keep walking a route to a source
      ;; that is gone, because following and depositing are separate rules —
      ;; deposition needs a full crop and there is nothing left to fill it.
      ;; So the road stops being renewed while the traffic on it continues,
      ;; and evaporation takes it out from under them.
      (let ((f (first (world-foods w))))
        ;; run on until the source is actually empty rather than guessing a
        ;; time, so the frames stay on the event if anything is recalibrated
        (loop repeat 60
              until (food-empty-p f)
              do (world-run! w 1200))
        (gallery-shot w "09-abandoned")
        (format t "~&  source empty at ~,0f s: pop ~d, trail ~,0f~%"
                (world-seconds w) (colony-population c)
                (field-total (colony-field c)))
        (world-run! w (* 1200 2))
        (gallery-shot w "10-fading")
        (format t "~&  +2 min: pop ~d, trail ~,0f~%"
                (colony-population c) (field-total (colony-field c)))
        (world-run! w (* 1200 4))
        (gallery-shot w "11-collapsed")
        (format t "~&  +6 min: pop ~d, trail ~,0f~%"
                (colony-population c) (field-total (colony-field c))))
      ;; Aftermath: with the source finite, an hour is long enough to exhaust
      ;; it and starve the colony.  Two §3.8 rows in one frame — trail death
      ;; and colony extinction — and the honest end of this scenario.
      (loop until (>= (world-seconds w) 3600.0f0)
            do (world-run! w 1200))
      (gallery-shot w "06-aftermath")
      (format t "~&  60 min: pop ~d, trail ~,0f, stock ~,0f~%"
              (colony-population c) (field-total (colony-field c))
              (colony-stock c))
      ;; The two published experiments, as pictures.
      ;;
      ;; These are the figures the README's opening claim rests on, and
      ;; they are rendered from the apparatus rather than drawn: the
      ;; asymmetry visible in each one was produced by the run, and by the
      ;; same code the acceptance rows assert on.
      (gallery-bridge :binary "12-binary-bridge" 2 12)
      ;; The hero: the double bridge committed to its short arm, framed
      ;; wide.  Chosen for the top of the README because it is the one
      ;; picture that is simultaneously pretty and *the result* — two
      ;; routes offered, one taken, and nothing in the model that can
      ;; measure a length.
      ;; Framed to the whole apparatus, not cropped to the corridors: the
      ;; picture has to show *two routes between the same two points*, so
      ;; the nest and the source both have to be in it or the claim in the
      ;; caption is not visible in the image.
      (let ((b (gallery-bridge :double "13-double-bridge" 2 12)))
        ;; Framed to the arena exactly rather than fitted to it: VIEW-FIT
        ;; letterboxes whenever the frame is wider than the world, and the
        ;; seam where the grid stops reads as a rendering fault in a picture
        ;; that is the first thing anyone sees.  Span is the world's full
        ;; width, and the height follows from the aspect and still contains
        ;; both the nest and the source — which it must, because the caption
        ;; claims two routes between the same two points.
        (gallery-shot (bridge-world b) "14-hero"
                      :width 1000 :height 740
                      :cx 0.35f0 :cy 0.30f0 :span 0.70f0))
      (values))))
