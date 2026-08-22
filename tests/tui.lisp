;;;; tests/tui.lisp — the terminal view (§5.6).
;;;;
;;;; In the core suite rather than in one of its own, and that is the
;;;; payoff of keeping tui/draw.lisp pure: a frame is a character grid
;;;; built by arithmetic, so everything below runs on a machine with no
;;;; terminal, no GPU and no graphics stack — the same machine the rest of
;;;; this suite is promised to run on.
;;;;
;;;; Only tui/term.lisp needs a tty, and there is nothing in it worth
;;;; testing that a tty would not have to be faked for.  What is worth
;;;; testing is the escape-sequence decoder, and that is a pure function
;;;; over a string precisely so that it can live here.

(in-package #:antsim/test)

(in-suite antsim)

;;; ------------------------------------------------------------ camera

(test a-camera-round-trips-a-world-point-through-a-cell
  "A cell centre must land back in its own cell.  If it does not, every
sample the field shading takes is off by one and the trail is drawn
beside itself."
  (let ((cam (ant:make-tui-camera :cx 0.3f0 :cy 0.2f0 :mpc 0.01f0)))
    (dolist (cell '((0 0) (40 12) (79 23) (13 7)))
      (destructuring-bind (col row) cell
        (multiple-value-bind (wx wy) (ant:tui-cell->world cam 80 24 col row)
          (multiple-value-bind (bc br) (ant:tui-world->cell cam 80 24 wx wy)
            (is (= bc col) "column ~a -> ~a" col bc)
            (is (= br row) "row ~a -> ~a" row br)))))))

(test the-camera-centre-is-the-centre-of-the-grid
  (let ((cam (ant:make-tui-camera :cx 0.3f0 :cy 0.2f0 :mpc 0.01f0)))
    (multiple-value-bind (col row) (ant:tui-world->cell cam 80 24 0.3f0 0.2f0)
      (is (= col 40))
      (is (= row 12)))))

(test a-cell-is-twice-as-tall-as-it-is-wide
  "The one piece of arithmetic in the terminal view that cannot be got
wrong by a little.  A terminal cell is about twice as tall as it is wide,
so the same distance must span twice as many columns as rows; pretend
otherwise and every circle in the world is drawn as an ellipse."
  (let ((cam (ant:make-tui-camera :cx 0.5f0 :cy 0.5f0 :mpc 0.01f0)))
    (multiple-value-bind (c0 r0) (ant:tui-world->cell cam 100 100 0.45f0 0.55f0)
      (multiple-value-bind (c1 r1) (ant:tui-world->cell cam 100 100 0.55f0 0.45f0)
        (is (= 10 (- c1 c0)) "0.1 m spanned ~a columns" (- c1 c0))
        (is (= 5 (- r1 r0)) "0.1 m spanned ~a rows" (- r1 r0))))))

(test fit-frames-the-whole-arena-in-both-dimensions
  "Whichever way round the arena and the terminal are, every corner has
to be on screen — that is the whole promise of the `f` key."
  (dolist (dims '((0.6f0 0.4f0 100 30) (0.4f0 0.6f0 100 30)
                  (1.0f0 1.0f0 40 60) (0.6f0 0.6f0 20 8)))
    (destructuring-bind (width height cols rows) dims
      (let* ((w (ant:make-world :width width :height height))
             (cam (ant:tui-fit w cols rows)))
        (dolist (corner (list (list 0.0f0 0.0f0) (list width 0.0f0)
                              (list 0.0f0 height) (list width height)))
          (destructuring-bind (x y) corner
            (multiple-value-bind (col row) (ant:tui-world->cell cam cols rows x y)
              (is (<= 0 col (1- cols)) "~a x ~a: corner ~a,~a at column ~a"
                  cols rows x y col)
              (is (<= 0 row (1- rows)) "~a x ~a: corner ~a,~a at row ~a"
                  cols rows x y row))))))))

(test panning-moves-the-centre-by-whole-cells
  "One key press moves the picture by one character, whatever the zoom.
Panning by a fixed distance in metres instead would crawl when zoomed out
and fly when zoomed in."
  (let* ((w (ant:make-world :width 2.0f0 :height 2.0f0))
         (cam (ant:make-tui-camera :cx 1.0f0 :cy 1.0f0 :mpc 0.01f0)))
    (ant:tui-pan! cam w 80 24 3 0)
    (is (< (abs (- (ant:tcam-cx cam) 1.03f0)) 1f-5))
    ;; Rows go down and world y goes up, so panning down lowers y.
    (ant:tui-pan! cam w 80 24 0 2)
    (is (< (abs (- (ant:tcam-cy cam) (- 1.0f0 0.04f0))) 1f-5))))

(test panning-cannot-lose-the-arena-off-the-screen
  "The GL camera deliberately does not clamp, and is right not to — in a
window you can see you have flown off and drag back.  A terminal full of
blank cells is indistinguishable from a program that has stopped."
  (let* ((w (ant:make-world :width 0.6f0 :height 0.6f0))
         (cam (ant:make-tui-camera :cx 0.3f0 :cy 0.3f0 :mpc 0.001f0)))
    ;; Zoomed well in, so the screen shows a fraction of the arena and
    ;; there is somewhere to pan off to.  Then pan hard into a corner,
    ;; far further than the arena is wide.
    (dotimes (i 5000) (ant:tui-pan! cam w 80 24 7 5))
    (flet ((inside-p (lo hi) (and (>= lo -1f-5) (<= hi (+ 0.6f0 1f-5)))))
      (multiple-value-bind (vw vh) (ant:tui-visible-span cam 80 24)
        (is (inside-p (- (ant:tcam-cx cam) (* 0.5f0 vw))
                      (+ (ant:tcam-cx cam) (* 0.5f0 vw)))
            "x span ~a..~a left the arena"
            (- (ant:tcam-cx cam) (* 0.5f0 vw)) (+ (ant:tcam-cx cam) (* 0.5f0 vw)))
        (is (inside-p (- (ant:tcam-cy cam) (* 0.5f0 vh))
                      (+ (ant:tcam-cy cam) (* 0.5f0 vh)))
            "y span ~a..~a left the arena"
            (- (ant:tcam-cy cam) (* 0.5f0 vh))
            (+ (ant:tcam-cy cam) (* 0.5f0 vh)))))
    ;; And the same the other way, so it is not merely stuck at one edge.
    (dotimes (i 5000) (ant:tui-pan! cam w 80 24 -7 -5))
    (is (>= (ant:tcam-cx cam) 0.0f0))
    (is (>= (ant:tcam-cy cam) 0.0f0))))

(test zooming-out-past-the-arena-simply-centres-it
  "There is nothing to pan to when the whole world is on screen, and a
camera that still moves is one that can put the arena in a corner."
  (let* ((w (ant:make-world :width 0.6f0 :height 0.6f0))
         (cam (ant:make-tui-camera :cx 0.1f0 :cy 0.1f0 :mpc 0.5f0)))
    (ant:tui-clamp! cam w 80 24)
    (is (< (abs (- (ant:tcam-cx cam) 0.3f0)) 1f-5))
    (is (< (abs (- (ant:tcam-cy cam) 0.3f0)) 1f-5))))

;;; ------------------------------------------------------------- glyph

(test a-bearing-glyph-is-chosen-in-screen-space-not-world-space
  "World y is up, terminal rows go down, so the glyph table is indexed by
the negated heading.  Indexed by the raw heading the picture is wrong in
exactly half of itself: the ants above the nest point correctly and the
ants below it point at their own reflection, which reads as two columns
of traffic going the same way.  This is a regression, not a hypothetical
— the first draft did it."
  (let ((half-pi (float (/ pi 2) 1.0f0))
        (quarter-pi (float (/ pi 4) 1.0f0))
        (whole-pi (float pi 1.0f0)))
    (is (char= #\→ (ant:tui-ant-glyph 0.0f0)))
    (is (char= #\↑ (ant:tui-ant-glyph half-pi)))
    (is (char= #\← (ant:tui-ant-glyph whole-pi)))
    (is (char= #\↓ (ant:tui-ant-glyph (- half-pi))))
    (is (char= #\↗ (ant:tui-ant-glyph quarter-pi)))
    (is (char= #\↘ (ant:tui-ant-glyph (- quarter-pi))))))

(test eight-headings-give-eight-unicode-glyphs-and-four-ascii-ones
  "The ASCII set's limitation, pinned so that nobody reads it as a bug: a
stroke has no arrowhead, so `\\` is both north-west and south-east and
what survives is the axis of travel rather than the direction along it.
It is why Unicode is the default."
  (let ((unicode '()) (ascii '()))
    (dotimes (k 8)
      (let ((th (float (/ (* 2 pi k) 8) 1.0f0)))
        (pushnew (ant:tui-ant-glyph th :unicode) unicode)
        (pushnew (ant:tui-ant-glyph th :ascii) ascii)))
    (is (= 8 (length unicode)) "unicode gave ~a distinct glyphs" (length unicode))
    (is (= 4 (length ascii)) "ascii gave ~a distinct glyphs" (length ascii))))

(test a-heading-is-wrapped-not-clamped
  "Headings arrive wrapped to (-pi, pi], but nothing here should break if
one does not — an angle is periodic and the table lookup must be too."
  (let ((two-pi (float (* 2 pi) 1.0f0)))
    (dolist (turn (list 0.0f0 two-pi (- two-pi) (* 5 two-pi)))
      (is (char= (ant:tui-ant-glyph 0.0f0)
                 (ant:tui-ant-glyph (+ 0.3f0 turn) ))
          "0.3 + ~a rad disagreed with itself" turn)
      (is (char= (ant:tui-ant-glyph 0.3f0) (ant:tui-ant-glyph (+ 0.3f0 turn)))))))

;;; ------------------------------------------------------------ canvas

(test a-canvas-diff-emits-only-the-cells-that-changed
  "The reason the terminal view does not flicker.  A full repaint of a
large terminal is twelve thousand cells a frame and looks like it."
  (let ((a (ant:make-tui-canvas 20 3))
        (b (ant:make-tui-canvas 20 3)))
    (is (null (ant:tui-canvas-diff a b)) "identical canvases differed")
    (ant:tui-put! b 5 1 #\x)
    (let ((runs (ant:tui-canvas-diff a b)))
      (is (= 1 (length runs)))
      (destructuring-bind (row col string fg) (first runs)
        (is (= row 1)) (is (= col 5)) (is (string= string "x"))
        (is (= fg ant:+tui-default+))))))

(test adjacent-changed-cells-become-one-run
  "One cursor placement and one write per run — which is what the whole
diff is for.  Emitting a cell at a time would be three escape sequences
per character."
  (let ((a (ant:make-tui-canvas 20 2))
        (b (ant:make-tui-canvas 20 2)))
    (ant:tui-write! b 4 0 "abc")
    (let ((runs (ant:tui-canvas-diff a b)))
      (is (= 1 (length runs)))
      (is (string= "abc" (third (first runs)))))
    ;; A colour change splits the run, because the writer sets colour once
    ;; per run and cannot say two things at one cursor position.
    (ant:tui-put! b 6 0 #\c 31)
    (is (= 2 (length (ant:tui-canvas-diff a b))))))

(test a-fresh-screen-is-entirely-a-change
  "After a resize nothing is where it was, so a diff against the old
screen is not merely useless but wrong."
  (let ((b (ant:make-tui-canvas 10 2)))
    (ant:tui-write! b 0 0 "hello")
    (is (plusp (length (ant:tui-canvas-diff nil b))))
    ;; a canvas of a different size counts as no canvas at all
    (is (plusp (length (ant:tui-canvas-diff (ant:make-tui-canvas 9 2) b))))))

(test the-first-frame-has-no-previous-screen-to-copy-over
  "On the very first frame, and on the first after a resize, there is no
previous canvas — and the loop still has to keep the one it just drew.
A regression: the copy declared its destination non-NIL and the loop
died on frame two, having rendered frame one perfectly."
  (let ((src (ant:make-tui-canvas 10 3)))
    (ant:tui-write! src 1 1 "hi")
    (let ((kept (ant:tui-canvas-copy! nil src)))
      (is (not (null kept)))
      (is (= 10 (ant:tcv-cols kept)))
      (is (char= #\h (ant:tui-at kept 1 1)))
      ;; and it is a copy, not the same object shared by reference
      (ant:tui-put! src 1 1 #\X)
      (is (char= #\h (ant:tui-at kept 1 1))))
    ;; a differently-sized destination is replaced rather than written into
    (let ((kept (ant:tui-canvas-copy! (ant:make-tui-canvas 4 4) src)))
      (is (= 10 (ant:tcv-cols kept)))
      (is (= 3 (ant:tcv-rows kept))))))

(test writing-off-the-edge-clips-instead-of-signalling
  "Almost everything drawn is at a world position that may or may not be
on screen; making every caller test that first would put the same three
lines in front of every draw loop."
  (let ((cv (ant:make-tui-canvas 5 2)))
    (finishes (ant:tui-put! cv -3 0 #\x))
    (finishes (ant:tui-put! cv 99 0 #\x))
    (finishes (ant:tui-put! cv 0 -1 #\x))
    (finishes (ant:tui-write! cv 3 0 "overlong"))
    (is (char= #\Space (ant:tui-at cv 0 0)))))

;;; -------------------------------------------------------------- draw

(defun %tui-world ()
  "A small world with a nest, a source and an obstacle."
  (let* ((w (ant:make-world :width 0.6f0 :height 0.6f0 :capacity 400 :seed 7))
         (c (ant:add-colony w :name "home" :nest-x 0.30f0 :nest-y 0.08f0
                              :nest-r 0.02f0 :capacity 200 :stock 500.0f0)))
    (ant:add-food w 0.34f0 0.43f0 0.03f0 2500.0f0 :quality 1.0f0)
    (ant:add-obstacle w '(0.12 0.20 0.30 0.20 0.30 0.235 0.12 0.235))
    (values w c)))

(test an-ant-outranks-the-food-it-is-standing-on
  "Draw order is the precedence, and the ants are the point of the
picture — a forager at a source that is drawn as the source is a forager
nobody can see arrive."
  (multiple-value-bind (w c) (%tui-world)
    (ant:world-seed-population! w c 1)
    (let* ((a (ant:world-ants w))
           (b (ant:world-bodies w))
           (bi (aref (ant:ants-body a) 0))
           (cam (ant:tui-fit w 60 30)))
      ;; stand the ant in the middle of the source, facing east
      (setf (aref (ant:bodies-x b) bi) 0.34f0
            (aref (ant:bodies-y b) bi) 0.43f0
            (aref (ant:ants-heading a) 0) 0.0f0)
      (let ((cv (ant:make-tui-canvas 60 30)))
        (ant:tui-draw-world! cv w cam :colour nil)
        (multiple-value-bind (col row) (ant:tui-world->cell cam 60 30 0.34f0 0.43f0)
          (is (char= #\→ (ant:tui-at cv col row))
              "the cell showed ~s" (ant:tui-at cv col row)))))))

(test a-dead-slot-is-not-drawn
  "ANTS-N is a high-water mark and not a population: slots below it are
freed and reused, and drawing one shows an ant that died some time ago
standing exactly where it fell."
  (multiple-value-bind (w c) (%tui-world)
    (ant:world-seed-population! w c 1)
    (let* ((a (ant:world-ants w))
           (b (ant:world-bodies w))
           (bi (aref (ant:ants-body a) 0))
           (cam (ant:tui-fit w 60 30)))
      ;; Somewhere with nothing else on it, so what is asserted is the ant
      ;; and not the nest underneath it.
      (setf (aref (ant:bodies-x b) bi) 0.55f0
            (aref (ant:bodies-y b) bi) 0.55f0
            (aref (ant:ants-heading a) 0) 0.0f0)
      (multiple-value-bind (col row) (ant:tui-world->cell cam 60 30 0.55f0 0.55f0)
        (let ((cv (ant:make-tui-canvas 60 30)))
          (ant:tui-draw-world! cv w cam :colour nil)
          (is (char= #\→ (ant:tui-at cv col row)) "the live ant was not drawn"))
        (ant:kill-ant w c 0)
        (is (not (ant:ant-live-p a 0)))
        (let ((cv (ant:make-tui-canvas 60 30)))
          (ant:tui-draw-world! cv w cam :colour nil)
          ;; A corpse is drawn where it fell — but as a corpse, never as
          ;; an ant still walking east.
          (is (char/= #\→ (ant:tui-at cv col row))
              "a dead slot was drawn as a live ant"))))))

(test nothing-outside-the-arena-is-shaded
  "FIELD-AT and FIELD-BLOCKED-P clamp to the edge cell rather than
signalling — the right choice for the ant loop, which never asks about a
point outside the world, and a trap here.  Zoom out until the arena is
smaller than the terminal and without a bounds test the edge row and
column smear outward across the whole screen."
  (multiple-value-bind (w c) (%tui-world)
    (declare (ignore c))
    ;; A wide-open camera: the 0.6 m arena occupies a fraction of the grid.
    (let ((cam (ant:make-tui-camera :cx 0.3f0 :cy 0.3f0 :mpc 0.05f0))
          (cv (ant:make-tui-canvas 60 30)))
      (ant:tui-draw-world! cv w cam :colour nil)
      ;; The far corners are metres outside the world.
      (dolist (cell '((0 0) (59 0) (0 29) (59 29)))
        (destructuring-bind (col row) cell
          (is (char= #\Space (ant:tui-at cv col row))
              "cell ~a,~a outside the arena showed ~s"
              col row (ant:tui-at cv col row)))))))

(test a-frame-is-a-rectangle-of-the-size-asked-for
  (multiple-value-bind (w c) (%tui-world)
    (ant:world-seed-population! w c 20)
    (dolist (dims '((100 40) (20 6) (1 1) (200 60)))
      (destructuring-bind (cols rows) dims
        (let ((cv (ant:tui-frame w :cols cols :rows rows :status t)))
          (is (= cols (ant:tcv-cols cv)))
          (is (= rows (ant:tcv-rows cv)))
          ;; and it prints, at any size, without signalling
          (finishes (ant:tui-canvas-string cv)))))))

;;; ------------------------------------------------------------ status

(test the-status-line-is-truncated-not-wrapped
  "A wrapped status line pushes the world down by a row, and the world
pane was sized on the assumption that it did not."
  (multiple-value-bind (w c) (%tui-world)
    (ant:world-seed-population! w c 30)
    (dolist (cols '(1 5 10 20 40 80 200))
      (let ((line (ant:tui-status w :cols cols)))
        (is (<= (length line) cols) "~a columns gave ~a characters: ~s"
            cols (length line) line)
        (is (not (find #\Newline line)) "the line wrapped at ~a columns" cols)))))

(test the-status-line-leads-with-the-clock-and-the-population
  "The window's fields, in the window's order.  Two views of one world
that report different numbers are worse than one view, because then
neither can be trusted."
  (multiple-value-bind (w c) (%tui-world)
    (ant:world-seed-population! w c 30)
    (let ((line (ant:tui-status w :cols 200)))
      (is (search "t " line))
      (is (search "ants" line))
      (is (search "stock" line))
      (is (search "trail" line)))))

(test a-speed-multiplier-does-not-print-its-padding
  "~G was the obvious directive and prints `1.0    x` — it pads to a
field width and the padding lands between the number and its unit."
  (multiple-value-bind (w c) (%tui-world)
    (declare (ignore c))
    (is (search "4x" (ant:tui-status w :cols 200 :speed 4.0f0)))
    (is (not (find #\Space (ant:tui-speed-string 4.0f0))))
    (is (not (find #\Space (ant:tui-speed-string 0.5f0))))
    (is (string= "1x" (ant:tui-speed-string 1.0f0)))
    (is (string= "0.5x" (ant:tui-speed-string 0.5f0)))))

;;; -------------------------------------------------------------- keys

(test an-arrow-key-decodes-to-a-direction
  (dolist (case '(("A" :up) ("B" :down) ("C" :right) ("D" :left)))
    (destructuring-bind (final key) case
      (let ((seq (format nil "~c[~a" ant:+tui-esc+ final)))
        (is (equal (list key) (ant:tui-decode-keys seq))
            "~s decoded to ~s" seq (ant:tui-decode-keys seq))))))

(test an-escape-sequence-split-across-two-reads-is-still-one-key
  "The terminal is under no obligation to deliver three bytes in one
read.  Decoded greedily, a split arrow key is a dropped key and a stray
`[A` printed into the world."
  (let ((esc (string ant:+tui-esc+)))
    ;; first read: just the ESC
    (multiple-value-bind (keys rest) (ant:tui-decode-keys esc)
      (is (null keys))
      (is (string= esc rest)))
    ;; and again with the bracket, still incomplete
    (multiple-value-bind (keys rest)
        (ant:tui-decode-keys (concatenate 'string esc "["))
      (is (null keys))
      (is (string= (concatenate 'string esc "[") rest)))
    ;; the tail arrives
    (multiple-value-bind (keys rest)
        (ant:tui-decode-keys (concatenate 'string esc "[" "A"))
      (is (equal '(:up) keys))
      (is (string= "" rest)))))

(test a-lone-escape-is-not-an-arrow-key
  "Nothing in the byte stream distinguishes the escape key from the first
byte of an arrow whose other two bytes have not arrived, so it is
resolved in time instead: held back until the caller says nothing more is
coming."
  (let ((esc (string ant:+tui-esc+)))
    (multiple-value-bind (keys rest) (ant:tui-decode-keys esc)
      (is (null keys) "a lone escape decoded immediately")
      (is (string= esc rest)))
    (multiple-value-bind (keys rest) (ant:tui-decode-keys esc :flush t)
      (is (equal '(:escape) keys))
      (is (string= "" rest)))))

(test ordinary-characters-pass-straight-through
  (multiple-value-bind (keys rest) (ant:tui-decode-keys "q z?")
    (is (equal '(#\q #\Space #\z #\?) keys))
    (is (string= "" rest))))

(test control-c-arrives-as-a-key-because-raw-mode-cleared-isig
  "Handled as a key so the loop can unwind and put the terminal back.  A
process killed by SIGINT here would leave the user in a shell with no
echo and the alternate screen still up."
  (is (equal '(:ctrl-c) (ant:tui-decode-keys (string (code-char 3))))))

(test a-shifted-arrow-is-its-own-key
  "`ESC [ 1 ; 2 A` — the 2 is the xterm modifier encoding for shift, and
it is what makes shift-arrow pan a page."
  (let ((seq (format nil "~c[1;2A" ant:+tui-esc+)))
    (is (equal '(:shift-up) (ant:tui-decode-keys seq)))))

(test application-mode-arrows-decode-too
  "Many terminals send ESC O A rather than ESC [ A once the keypad is in
application mode.  Same finals, one byte shorter, and a view that does
not know about them is one whose arrow keys stop working halfway through
a session."
  (is (equal '(:left) (ant:tui-decode-keys (format nil "~cOD" ant:+tui-esc+)))))

(test a-run-of-keys-decodes-in-order
  "What a fast typist and a held-down arrow key both look like."
  (let ((seq (format nil "~c[A~c[Bq" ant:+tui-esc+ ant:+tui-esc+)))
    (is (equal '(:up :down #\q) (ant:tui-decode-keys seq)))))

(test the-key-legend-is-data
  "A legend that is a list can be printed by the help overlay, checked by
a test, and pasted into the docs without three copies of it drifting
apart — the same choice *LIVE-KEYS* makes in the window."
  (is (every (lambda (k) (and (stringp (first k)) (stringp (second k))))
             ant:*tui-keys*))
  (is (= (length ant:*tui-keys*) (length (ant:tui-help-lines))))
  (is (find "quit" ant:*tui-keys* :key #'second :test #'string=)))
