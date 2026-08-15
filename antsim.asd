;;;; antsim.asd
;;;;
;;;; Four systems, and the split is the one from docs/concept.md §4.1: the numeric
;;;; core has no dependencies at all, so the simulation can be built and
;;;; tested on a machine with no GPU and no graphics stack.  Only
;;;; antsim/render knows that OpenGL exists.

(defsystem "antsim"
  :description "A 2D ant colony simulation on real behavioural science — numeric core."
  :author "Mathias Menzel-Nielsen"
  :version "0.2.1"        ; milestone M2.1
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
   (:file "ant/step")
   ;; The §3.8 bridge apparatus.  Last, because it builds worlds and runs
   ;; ticks and therefore needs everything above it — and because nothing
   ;; above it may depend on an experiment.
   (:file "world/bridge"))
  :in-order-to ((test-op (test-op "antsim/test"))))

(defsystem "antsim/scenario"
  :description "The JSON scenario format (§6).  Owns the JSON dependency."
  ;; §4.1: the core never sees a parser.  This is the only system that
  ;; knows JSON exists, and nothing in `antsim` depends on it.
  :depends-on ("antsim" "com.inuoe.jzon")
  :serial t
  :pathname "src/scenario"
  :components ((:file "load")))

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
               (:file "renderer")
               (:file "hud")
               (:file "gallery"))
  :in-order-to ((test-op (test-op "antsim/render-test"))))

(defsystem "antsim/live"
  :description "Interactive window: GLFW, ortho camera, zoom and pan (§5.5)."
  ;; The same preload as the headless path, and for the same reason: the
  ;; window's GL and the process's GL have to be one implementation (§5.4).
  :defsystem-depends-on ("antsim-gl-preload")
  ;; antsim/scenario so the window is a playground for scenario *files*
  ;; and not only for worlds written in Lisp — §6's format is worth very
  ;; little if the only way to look at one is to render it headless.
  :depends-on ("antsim/render" "antsim/scenario" "cl-glfw3")
  :serial t
  :pathname "src/live"
  :components ((:file "window")))

(defsystem "antsim/test"
  :description "Test suite for the antsim core.  No GPU required."
  ;; antsim/scenario, not just antsim: the shipped bridge scenarios must be
  ;; checked against the Lisp constructors, and a test that cannot read the
  ;; files cannot do that.  The *core* still has no parser (§4.1).
  :depends-on ("antsim" "antsim/scenario" "fiveam")
  :serial t
  :pathname "tests"
  :components ((:file "suite")
               (:file "world")
               (:file "bodies")
               (:file "ant")
               (:file "scenario")
               ;; Its own FiveAM suite, not part of `antsim`: these are
               ;; colony runs over several seeds and they are slow, so
               ;; `make test` stays fast and `make acceptance` is what
               ;; says the science works.
               (:file "acceptance"))
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
