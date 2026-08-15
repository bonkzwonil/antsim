;;;; scenario/load.lisp — the JSON scenario format (§6).
;;;;
;;;; This system owns the JSON dependency so the core never sees a parser
;;;; (§4.1).  Everything here turns a file into the same calls a Lisp
;;;; scenario would have made by hand — ADD-COLONY, ADD-FOOD,
;;;; ADD-OBSTACLE, ADD-BRIDGE! — and then gets out of the way.
;;;;
;;;; **Validation is strict, and errors name the offending path.**  That
;;;; is §6's rule and it is worth the code: a scenario key that is
;;;; silently ignored because it was misspelled produces a run that looks
;;;; plausible and answers a different question than the one asked, and
;;;; the only symptom is a number you have no reason to distrust.  So an
;;;; unknown key is an error, a key of the wrong type is an error, and
;;;; both say where.
;;;;
;;;; Note what the format still cannot express, exactly as §6 requires: no
;;;; ant positions and no pheromone.  There is no key for either, and
;;;; adding one would make every result meaningless.

(in-package #:antsim)

(define-condition scenario-error (error)
  ((path :initarg :path :reader scenario-error-path)
   (detail :initarg :detail :reader scenario-error-detail)
   (source :initarg :source :initform nil :reader scenario-error-source))
  (:report (lambda (c s)
             (format s "~@[~a: ~]~a: ~a"
                     (scenario-error-source c)
                     (scenario-error-path c)
                     (scenario-error-detail c)))))

(defun serr (path fmt &rest args)
  (error 'scenario-error :path path :detail (apply #'format nil fmt args)))

;;; --------------------------------------------------------------------
;;; Reading the parse tree
;;; --------------------------------------------------------------------
;;;
;;; jzon hands back hash tables with string keys, vectors for arrays, and
;;; T / NIL / :NULL for the three literals.  These helpers do the type
;;; checking in one place so the loader below reads as a description of
;;; the format rather than as a pile of assertions.

(defun jpath (path key)
  (if (zerop (length path)) (string key) (format nil "~a.~a" path key)))

(defun jobject (v path)
  (unless (hash-table-p v) (serr path "expected an object"))
  v)

(defun jarray (v path)
  (unless (and (vectorp v) (not (stringp v))) (serr path "expected an array"))
  v)

(defun jnumber (v path)
  (unless (realp v) (serr path "expected a number, got ~s" v))
  (float v 1.0f0))

(defun jinteger (v path)
  (unless (and (realp v) (= v (truncate v)))
    (serr path "expected a whole number, got ~s" v))
  (truncate v))

(defun jstring (v path)
  (unless (stringp v) (serr path "expected a string, got ~s" v))
  v)

(defun jget (obj key path)
  "Value at KEY, or :MISSING.  PATH is only used for error text."
  (declare (ignore path))
  (multiple-value-bind (v found) (gethash (string-downcase key) obj)
    (if found v :missing)))

(defun jreq (obj key path reader)
  (let ((v (jget obj key path)))
    (when (eq v :missing) (serr (jpath path key) "required key is missing"))
    (funcall reader v (jpath path key))))

(defun jopt (obj key path reader default)
  (let ((v (jget obj key path)))
    (if (eq v :missing) default (funcall reader v (jpath path key)))))

(defparameter *deferred-keys*
  '(("clock" . "the multi-rate clocks are fixed at M1's rates (§4.3)")
    ("species" . "only the Lasius niger set exists (§3.1)")
    ("bodies" . "ant radius and relaxation are global parameters for now")
    ("brood_per_stock" . "colony growth constants are global, not per colony")
    ("max_age_s" . "colony growth constants are global, not per colony"))
  "Keys §6 documents that this loader does not implement yet.

Listed rather than lumped in with typos, because the two need different
answers: a typo is a mistake in the file, and one of these is a mistake
in my expectations of the program.  Telling them apart is most of what
makes an error message worth reading.")

(defun comment-key-p (k)
  "Keys beginning with `_` are comments and are ignored.

JSON has no comment syntax, and a scenario that cannot say *why* it uses
a number is a scenario whose numbers get changed by someone who does not
know.  The underscore convention costs nothing here: strictness exists to
catch typos, and a typo does not begin with an underscore."
  (and (plusp (length k)) (char= #\_ (char k 0))))

(defun check-keys (obj allowed path)
  "Every key must be one this loader acts on.  §6's rule, and the reason
for it is that a silently-defaulted typo costs an afternoon."
  (maphash (lambda (k v)
             (declare (ignore v))
             (unless (or (comment-key-p k)
                         (member k allowed :test #'string=))
               (let ((deferred (assoc k *deferred-keys* :test #'string=)))
                 (if deferred
                     (serr (jpath path k)
                           "documented in §6 but not implemented yet — ~a"
                           (cdr deferred))
                     (serr (jpath path k)
                           "unknown key; expected one of ~{~a~^, ~}"
                           allowed)))))
           obj))

;;; --------------------------------------------------------------------
;;; The scenario
;;; --------------------------------------------------------------------

(defstruct (scenario (:constructor %make-scenario))
  (name "" :type string)
  (world nil :type (or null world))
  (colonies '() :type list)
  (foods '() :type list)
  (seed +default-seed+ :type (unsigned-byte 32))
  (duration 0.0f0 :type f32)            ; seconds; 0 means "unbounded"
  ;; Parameter overrides, as (symbol . value).  Kept rather than applied,
  ;; because they have to be in force for the *run* and not only for the
  ;; construction — a scenario that sets tau and then runs under the
  ;; default tau would be a particularly cruel bug.
  (params '() :type list))

(defmacro with-scenario-params ((s) &body body)
  "Run BODY with the scenario's parameter overrides in force."
  (let ((g (gensym "S")))
    `(let ((,g ,s))
       (progv (mapcar #'car (scenario-params ,g))
              (mapcar #'cdr (scenario-params ,g))
         ,@body))))

;;; --------------------------------------------------------------------
;;; Obstacle primitives
;;; --------------------------------------------------------------------

(defun load-polygon (spec path)
  (let* ((pts (jarray spec path))
         (coords '()))
    (when (< (length pts) 3)
      (serr path "a polygon needs at least three points, got ~d" (length pts)))
    (loop for p across pts
          for i from 0
          do (let ((pair (jarray p (format nil "~a[~d]" path i))))
               (unless (= 2 (length pair))
                 (serr (format nil "~a[~d]" path i)
                       "expected [x, y], got ~d values" (length pair)))
               (push (jnumber (aref pair 0) (format nil "~a[~d][0]" path i))
                     coords)
               (push (jnumber (aref pair 1) (format nil "~a[~d][1]" path i))
                     coords)))
    (nreverse coords)))

(defun load-bridge-primitive (w spec path)
  "The `bridge` obstacle primitive (§6).

A bridge is three or more polygons whose coordinates are all derived from
four numbers, so writing it out by hand in JSON would be both unreadable
and wrong — and wrong in the specific way that matters: an extra way
through the band that nobody notices.  Expanding it here calls exactly
the same ADD-BRIDGE! the Lisp constructors use, so a bridge cannot come
to mean one thing in a scenario file and another in an acceptance run."
  (let ((o (jobject spec path)))
    (check-keys o '("y_lo" "y_hi" "corridor_width" "arms") path)
    (let* ((y-lo (jreq o "y_lo" path #'jnumber))
           (y-hi (jreq o "y_hi" path #'jnumber))
           (cw (jopt o "corridor_width" path #'jnumber 0.06f0))
           (arms (jarray (jreq o "arms" path (lambda (v p) (jarray v p)))
                         (jpath path "arms")))
           (bottoms '()) (tops '()))
      (when (< (length arms) 2)
        (serr (jpath path "arms")
              "a bridge needs at least two arms, got ~d" (length arms)))
      (loop for a across arms
            for i from 0
            do (let* ((ap (format nil "~a.arms[~d]" path i))
                      (ao (jobject a ap)))
                 (check-keys ao '("bottom" "top") ap)
                 (let ((b (jreq ao "bottom" ap #'jnumber)))
                   (push b bottoms)
                   (push (jopt ao "top" ap #'jnumber b) tops))))
      (setf bottoms (nreverse bottoms) tops (nreverse tops))
      (unless (apply #'< bottoms)
        (serr (jpath path "arms")
              "arms must be given left to right by their bottom mouth; got ~a"
              bottoms))
      (add-bridge! w :y-lo y-lo :y-hi y-hi :corridor-width cw
                     :bottoms bottoms :tops tops))))

(defun load-obstacle (w spec path)
  (let ((o (jobject spec path)))
    (check-keys o '("polygon" "rect" "bridge") path)
    (cond
      ((not (eq :missing (jget o "polygon" path)))
       (add-obstacle w (load-polygon (jget o "polygon" path)
                                     (jpath path "polygon"))))
      ((not (eq :missing (jget o "bridge" path)))
       (load-bridge-primitive w (jget o "bridge" path) (jpath path "bridge")))
      ((not (eq :missing (jget o "rect" path)))
       (let* ((rp (jpath path "rect"))
              (r (jobject (jget o "rect" path) rp)))
         (check-keys r '("x0" "y0" "x1" "y1") rp)
         (let ((x0 (jreq r "x0" rp #'jnumber)) (y0 (jreq r "y0" rp #'jnumber))
               (x1 (jreq r "x1" rp #'jnumber)) (y1 (jreq r "y1" rp #'jnumber)))
           (add-obstacle w (list x0 y0  x1 y0  x1 y1  x0 y1)))))
      (t (serr path "an obstacle needs one of: polygon, rect, bridge")))))

;;; --------------------------------------------------------------------
;;; The loader
;;; --------------------------------------------------------------------

(defun collect-param-overrides (root)
  "Parameter overrides, as (symbol . value), from `choice` and
`pheromones.trail`."
  (let ((out '()))
    (let ((choice (jget root "choice" "")))
      (unless (eq choice :missing)
        (let ((c (jobject choice "choice")))
          (check-keys c '("n" "k" "eavesdrop") "choice")
          (flet ((put (key var)
                   (let ((v (jget c key "choice")))
                     (unless (eq v :missing)
                       (push (cons var (jnumber v (jpath "choice" key)))
                             out)))))
            (put "n" '*choice-n*)
            (put "k" '*choice-k*)
            (put "eavesdrop" '*choice-eavesdrop*)))))
    (let ((ph (jget root "pheromones" "")))
      (unless (eq ph :missing)
        (let ((p (jobject ph "pheromones")))
          (check-keys p '("trail") "pheromones")
          (let ((trail (jget p "trail" "pheromones")))
            (unless (eq trail :missing)
              (let ((tr (jobject trail "pheromones.trail")))
                (check-keys tr '("tau_s" "max" "deposit" "decay_scale"
                                 "packet_spacing" "packet_radius"
                                 "packet_falloff")
                            "pheromones.trail")
                (flet ((put (key var)
                         (let ((v (jget tr key "pheromones.trail")))
                           (unless (eq v :missing)
                             (push (cons var
                                         (jnumber v (jpath "pheromones.trail"
                                                           key)))
                                   out)))))
                  (put "tau_s" '*trail-tau*)
                  (put "max" '*trail-cap*)
                  (put "deposit" '*trail-deposit*)
                  (put "decay_scale" '*trail-decay-scale*)
                  (put "packet_spacing" '*trail-packet-spacing*)
                  (put "packet_radius" '*trail-packet-radius*)
                  (put "packet_falloff" '*trail-packet-falloff*))))))))
    (nreverse out)))

(defun parse-scenario (root &key source seed)
  "Build a SCENARIO from a parsed JSON object.

SEED, if given, overrides the file's.  It has to be applied here rather
than set afterwards, because the seed is fixed when the world is built
and the starting population is placed with it."
  (handler-bind ((scenario-error
                   (lambda (c)
                     (when (and source (null (scenario-error-source c)))
                       (setf (slot-value c 'source) source)))))
    (let ((r (jobject root "")))
      (check-keys r '("name" "world" "seed" "duration_s" "choice" "pheromones"
                      "colonies" "food" "obstacles")
                  "")
      (let* ((name (jopt r "name" "" #'jstring "scenario"))
             (seed (or seed (jopt r "seed" "" #'jinteger +default-seed+)))
             (duration (jopt r "duration_s" "" #'jnumber 0.0f0))
             (wp "world")
             (wobj (jobject (jreq r "world" "" (lambda (v p) v)) wp))
             (overrides (collect-param-overrides r)))
        (check-keys wobj '("width" "height" "capacity") wp)
        (let ((width (jreq wobj "width" wp #'jnumber))
              (height (jreq wobj "height" wp #'jnumber))
              (capacity (jopt wobj "capacity" wp #'jinteger 4000)))
          ;; Overrides are in force while the world is built, because some
          ;; of them (tau, cap) are read by MAKE-FIELD at construction and
          ;; would otherwise silently keep their defaults.
          (progv (mapcar #'car overrides) (mapcar #'cdr overrides)
            (let ((w (make-world :width width :height height
                                 :capacity capacity :seed seed))
                  (colonies '()) (foods '()))
              ;; obstacles first: MAKE-COLONY rasterizes what is already
              ;; there into the new field's blocked mask
              (let ((obs (jopt r "obstacles" "" (lambda (v p) (jarray v p))
                               #())))
                (loop for o across obs
                      for i from 0
                      do (load-obstacle w o (format nil "obstacles[~d]" i))))
              (let ((cs (jopt r "colonies" "" (lambda (v p) (jarray v p)) #())))
                (when (zerop (length cs))
                  (serr "colonies" "a scenario needs at least one colony"))
                (loop for c across cs
                      for i from 0
                      do (push (load-colony w c (format nil "colonies[~d]" i))
                               colonies)))
              (let ((fs (jopt r "food" "" (lambda (v p) (jarray v p)) #())))
                (loop for f across fs
                      for i from 0
                      do (push (load-food w f (format nil "food[~d]" i))
                               foods)))
              (%make-scenario :name name :world w
                              :colonies (nreverse colonies)
                              :foods (nreverse foods)
                              :seed seed :duration duration
                              :params overrides))))))))

(defun load-colony (w spec path)
  (let ((o (jobject spec path)))
    (check-keys o '("id" "nest" "capacity" "start" "stock") path)
    (let* ((id (jopt o "id" path #'jstring "colony"))
           (np (jpath path "nest"))
           (nest (jobject (jreq o "nest" path (lambda (v p) v)) np)))
      (check-keys nest '("x" "y" "r") np)
      (let ((c (add-colony w :name id
                             :nest-x (jreq nest "x" np #'jnumber)
                             :nest-y (jreq nest "y" np #'jnumber)
                             :nest-r (jopt nest "r" np #'jnumber 0.02f0)
                             :capacity (jopt o "capacity" path #'jinteger 2000)
                             :stock (jopt o "stock" path #'jnumber 100.0f0))))
        ;; `start` seeds a count at the nest, never a layout (§6)
        (world-seed-population! w c (jopt o "start" path #'jinteger 0))
        c))))

(defun load-food (w spec path)
  (let ((o (jobject spec path)))
    (check-keys o '("x" "y" "r" "amount" "quality" "renew_per_min" "density")
                path)
    ;; `r` and `density` say the same thing two ways: with `density` the
    ;; radius is derived from the amount and is therefore *absolute*, so
    ;; two sources can be compared by eye.  With only `r` it is the radius
    ;; at the starting amount, which is how every scenario behaved before
    ;; density existed.
    (add-food w (jreq o "x" path #'jnumber)
                (jreq o "y" path #'jnumber)
                (jopt o "r" path #'jnumber 0.03f0)
                (jreq o "amount" path #'jnumber)
                :quality (jopt o "quality" path #'jnumber 1.0f0)
                :renew (jopt o "renew_per_min" path #'jnumber 0.0f0)
                :density (jopt o "density" path #'jnumber nil))))

(defun load-scenario (path &key seed)
  "Read a scenario file (§6).  Signals SCENARIO-ERROR, naming the key.

SEED overrides the file's own, so one scenario can be run as many
different replicates without editing it."
  (unless (probe-file path)
    ;; Relative paths are resolved against the process's directory, which
    ;; is rarely where someone thinks it is when the command came through
    ;; make or a shell alias.  Say what was actually looked for.
    (error 'scenario-error
           :source (namestring path) :path "file"
           :detail (format nil "no such file (looked in ~a)"
                           (namestring (truename *default-pathname-defaults*)))))
  (let ((root (handler-case (with-open-file (s path :external-format :utf-8)
                              (com.inuoe.jzon:parse s))
                (scenario-error (e) (error e))
                (error (e)
                  (error 'scenario-error :source (file-namestring path)
                                         :path "json"
                                         :detail (format nil "~a" e))))))
    (parse-scenario root :source (file-namestring path) :seed seed)))

(defun load-scenario-string (text &key (source "<string>") seed)
  (parse-scenario (com.inuoe.jzon:parse text) :source source :seed seed))
