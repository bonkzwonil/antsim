;;;; antsim.asd
;;;;
;;;; Four systems, and the split is the one from README §4.1: the numeric
;;;; core has no dependencies at all, so the simulation can be built and
;;;; tested on a machine with no GPU and no graphics stack.  Only
;;;; antsim/render knows that OpenGL exists.

(defsystem "antsim"
  :description "A 2D ant colony simulation on real behavioural science — numeric core."
  :author "Bonk"
  :version "0.0.1"
  :license "MIT"
  :depends-on ()                        ; core stays dependency-free (sb-thread only)
  :serial t
  :pathname "src"
  :components
  ((:file "package")
   (:file "util")
   (:file "rng")
   (:file "pool")
   (:file "params")
   ;; Deliberately a flat, explicit order rather than two modules.  The
   ;; ant *table* has no knowledge of the world and must be built before
   ;; MAKE-WORLD can allocate one; the ant *tick* needs colonies, bodies
   ;; and fields and therefore comes last.  Splitting them across the
   ;; world files is what keeps the dependency acyclic without a single
   ;; forward declaration.
   (:file "ant/state")
   (:file "world/geom")
   (:file "world/grid")
   (:file "world/bodies")
   (:file "world/scene")
   (:file "ant/step"))
  :in-order-to ((test-op (test-op "antsim/test"))))

(defsystem "antsim/render"
  :description "Headless GL 4.5 via EGL, offscreen targets, PNG capture."
  ;; antsim-gl-preload lives in its own .asd and is pulled in here, not in
  ;; :depends-on, because it must load *before* cl-opengl — see
  ;; src/render/preload.lisp.
  :defsystem-depends-on ("antsim-gl-preload")
  :depends-on ("antsim" "cffi" "cl-opengl")
  :serial t
  :pathname "src/render"
  :components ((:file "png")
               (:file "egl")
               (:file "offscreen")
               (:file "smoke")
               (:file "view")
               (:file "shaders")
               (:file "renderer"))
  :in-order-to ((test-op (test-op "antsim/render-test"))))

(defsystem "antsim/live"
  :description "Interactive window: GLFW, ortho camera, zoom and pan (§5.5)."
  ;; The same preload as the headless path, and for the same reason: the
  ;; window's GL and the process's GL have to be one implementation (§5.4).
  :defsystem-depends-on ("antsim-gl-preload")
  :depends-on ("antsim/render" "cl-glfw3")
  :serial t
  :pathname "src/live"
  :components ((:file "window")))

(defsystem "antsim/test"
  :description "Test suite for the antsim core.  No GPU required."
  :depends-on ("antsim" "fiveam")
  :serial t
  :pathname "tests"
  :components ((:file "suite")
               (:file "world")
               (:file "bodies")
               (:file "ant"))
  :perform (test-op (o c)
             (symbol-call :fiveam :run!
                          (find-symbol (string :antsim) :antsim/test))))

(defsystem "antsim/render-test"
  :description "Renderer tests.  GL tests skip when no context is available."
  :depends-on ("antsim/render" "fiveam")
  :serial t
  :pathname "tests"
  :components ((:file "render")
               (:file "view"))
  :perform (test-op (o c)
             (symbol-call :fiveam :run!
                          (find-symbol (string :render) :antsim/render-test))))
