;;;; render/png.lisp — minimal PNG writer, no dependencies.
;;;;
;;;; A headless run proves the renderer works by producing a picture, so
;;;; the writer has to exist before anything it would photograph.  It
;;;; emits stored (BTYPE=00) deflate blocks — a valid zlib stream that
;;;; needs no compressor, at the cost of about 0.03 % size overhead.  That
;;;; is the right trade for capture output: nothing here is in a hot path,
;;;; and the alternative is a dependency in the one place where a
;;;; dependency would be hardest to justify.

(in-package #:antsim)

(defparameter *crc-table*
  (let ((table (make-array 256 :element-type '(unsigned-byte 32))))
    (dotimes (n 256 table)
      (let ((c n))
        (dotimes (k 8)
          (setf c (if (oddp c)
                      (logxor #xEDB88320 (ash c -1))
                      (ash c -1))))
        (setf (aref table n) c)))))

(defun crc32 (bytes &key (start 0) (end (length bytes)))
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (let ((c #xFFFFFFFF))
    (declare (type (unsigned-byte 32) c))
    (loop for i from start below end
          do (setf c (logxor (aref *crc-table*
                                   (logand #xFF (logxor c (aref bytes i))))
                             (ash c -8))))
    (logxor c #xFFFFFFFF)))

(defun adler32 (bytes)
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (let ((a 1) (b 0))
    (declare (type (unsigned-byte 32) a b))
    (loop for x across bytes
          do (setf a (mod (+ a x) 65521)
                   b (mod (+ b a) 65521)))
    (logior (ash b 16) a)))

(defun write-u32be (stream n)
  (write-byte (ldb (byte 8 24) n) stream)
  (write-byte (ldb (byte 8 16) n) stream)
  (write-byte (ldb (byte 8 8) n) stream)
  (write-byte (ldb (byte 8 0) n) stream))

(defun write-chunk (stream type data)
  "TYPE is a 4-character string; DATA an (unsigned-byte 8) vector.
The CRC covers the type *and* the data, which is the detail a hand-rolled
PNG writer usually gets wrong."
  (let* ((tlen (length type))
         (buf (make-array (+ tlen (length data))
                          :element-type '(unsigned-byte 8))))
    (dotimes (i tlen) (setf (aref buf i) (char-code (char type i))))
    (replace buf data :start1 tlen)
    (write-u32be stream (length data))
    (write-sequence buf stream)
    (write-u32be stream (crc32 buf))))

(defun deflate-stored (raw)
  "Wrap RAW in a zlib stream of stored deflate blocks."
  (declare (type (simple-array (unsigned-byte 8) (*)) raw))
  (let* ((n (length raw))
         (nblocks (max 1 (ceiling n 65535)))
         (out (make-array (+ 2 (* 5 nblocks) n 4)
                          :element-type '(unsigned-byte 8)))
         (p 0))
    (flet ((emit (b) (setf (aref out p) b) (incf p)))
      (emit #x78) (emit #x01)                    ; zlib header, no preset dict
      (let ((off 0))
        (loop while (or (< off n) (zerop n))
              do (let* ((len (min 65535 (- n off)))
                        (final (if (>= (+ off len) n) 1 0)))
                   (emit final)
                   (emit (logand #xFF len))
                   (emit (logand #xFF (ash len -8)))
                   (emit (logand #xFF (lognot len)))
                   (emit (logand #xFF (ash (lognot len) -8)))
                   (replace out raw :start1 p :start2 off :end2 (+ off len))
                   (incf p len)
                   (incf off len)
                   (when (= final 1) (return)))))
      (let ((a (adler32 raw)))
        (emit (ldb (byte 8 24) a)) (emit (ldb (byte 8 16) a))
        (emit (ldb (byte 8 8) a)) (emit (ldb (byte 8 0) a))))
    (subseq out 0 p)))

(defun write-png (path pixels width height &key (channels 3) (flip t))
  "Write PIXELS (row-major, CHANNELS bytes per pixel) to PATH as a PNG.
FLIP reverses row order, which is what OpenGL's bottom-up glReadPixels
output needs — so it defaults to true, because every caller in this
project is a frame capture."
  (declare (type (simple-array (unsigned-byte 8) (*)) pixels)
           (type fixnum width height channels))
  (let* ((stride (* width channels))
         (raw (make-array (* height (1+ stride))
                          :element-type '(unsigned-byte 8))))
    (dotimes (row height)
      (let ((src (* (if flip (- height 1 row) row) stride))
            (dst (* row (1+ stride))))
        (setf (aref raw dst) 0)                  ; filter type: none
        (replace raw pixels :start1 (1+ dst) :start2 src :end2 (+ src stride))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence #(137 80 78 71 13 10 26 10) out)
      (let ((ihdr (make-array 13 :element-type '(unsigned-byte 8))))
        (setf (aref ihdr 0) (ldb (byte 8 24) width)
              (aref ihdr 1) (ldb (byte 8 16) width)
              (aref ihdr 2) (ldb (byte 8 8) width)
              (aref ihdr 3) (ldb (byte 8 0) width)
              (aref ihdr 4) (ldb (byte 8 24) height)
              (aref ihdr 5) (ldb (byte 8 16) height)
              (aref ihdr 6) (ldb (byte 8 8) height)
              (aref ihdr 7) (ldb (byte 8 0) height)
              (aref ihdr 8) 8                    ; bit depth
              (aref ihdr 9) (ecase channels (3 2) (4 6))
              (aref ihdr 10) 0 (aref ihdr 11) 0 (aref ihdr 12) 0)
        (write-chunk out "IHDR" ihdr))
      (write-chunk out "IDAT" (deflate-stored raw))
      (write-chunk out "IEND" (make-array 0 :element-type '(unsigned-byte 8)))))
  path)
