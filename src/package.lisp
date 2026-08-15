;;;; package.lisp
;;;;
;;;; One package for the whole project, exported symbol by symbol.  The
;;;; simulation is a small number of large flat tables (README §4.2), not a
;;;; class hierarchy, and splitting that across packages buys nothing but
;;;; qualified names in the tick loop.

(defpackage #:antsim
  (:use #:cl)
  (:nicknames #:ant)
  (:export
   ;; util — types and array constructors
   #:f32 #:f32v #:u32v #:u16v #:u8v #:fixv
   #:mkf32 #:mku32 #:mku16 #:mku8 #:mkfix
   #:clampf #:lerpf #:sqf
   ;; rng — counter-based, no global state (§4.4)
   #:hash32 #:rnd-u32 #:rnd01 #:+default-seed+
   ;; pool — persistent workers (§4.5)
   #:pool #:make-worker-pool #:pool-run #:pool-shutdown #:pool-n
   ;; render/png (antsim/render)
   #:write-png #:crc32 #:adler32
   ;; render/egl
   #:gl-context #:make-headless-context #:destroy-gl-context
   #:with-headless-gl #:with-gl-traps-masked #:gl-info
   #:gl-context-width #:gl-context-height
   ;; render/offscreen
   #:offscreen #:make-offscreen #:destroy-offscreen #:with-offscreen
   #:offscreen-fbo #:offscreen-width #:offscreen-height
   #:bind-offscreen #:read-offscreen #:capture-offscreen
   #:compile-shader #:link-program
   ;; render/smoke — the M0 acceptance frame
   #:draw-smoke-frame #:render-smoke-png #:m0-smoke))
