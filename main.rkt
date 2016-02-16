#lang racket/base


(require racket/draw
         racket/class
         racket/contract
         math/matrix
         racket/list
         racket/vector
         racket/math
         data/queue)

(provide (contract-out (rotate (-> real? transformation?))
                       (scale (->* (real?) (real?) transformation?))
                       (translate (-> real? real? transformation?))
                       (combine-transformation (->* () ()  #:rest (listof transformation?) transformation?))
                       (render-shape (-> shape? (is-a?/c dc<%>) any/c))
                       (make-square shape-constructor?)
                       (make-circle shape-constructor?)
                       (maximum-render-cycles parameter?))
         define-shape
         loop-shape)

; Parameter that controls how many shapes to render
(define maximum-render-cycles (make-parameter 100))

;; Linear algebra combinators

(define (rotation-matrix theta)
  (matrix [[(cos theta) (- (sin theta)) 0]
           [(sin theta) (cos theta)     0]
           [0           0               1]]))

(define (scaling-matrix sx sy)
  (matrix [[sx 0  0]
           [0  sy 0]
           [0  0  1]]))

(define (translation-matrix dx dy)
  (matrix [[1 0 dx]
           [0 1 dy]
           [0 0 1 ]]))


;; transformation definition

; - geometric: matrix?
; - color: (vector/c real? real? real?) -- HSV deltas
(struct transformation (geometric color) #:transparent)

;; Transformations constructors

(define (geometric-transformation matrix)
  (transformation matrix #[0 0 0]))

(define (color-transformation hsb)
  (transformation (identity-matrix 3) hsb))

(define (identity)
  (geometric-transformation (identity-matrix 3)))

(define (rotate theta)
  (geometric-transformation (rotation-matrix theta)))

(define (scale sx [sy sx])
  (geometric-transformation (scaling-matrix sx sy)))

(define (translate tx ty)
  (geometric-transformation (translation-matrix tx ty)))

(define (hue h)
  (color-transformation (vector h 0 0)))

(define (saturation s)
  (color-transformation (vector 0 s 0)))

(define (brightness b)
  (color-transformation (vector 0 0 b)))

;; Transformations combinators
(define (combine-transformation . trans)
  (foldl (λ (a b) (transformation (matrix* (transformation-geometric b)
                                           (transformation-geometric a))
                                  (vector-map + (transformation-color a)
                                              (transformation-color b))))
         (identity)
         trans))

; Types:
; shape-renderer    : (-> (is-a?/c dc%) (listof shape-renderer?))
; shape             : (-> transformation? shape-renderer?)
; shape-constructor : (-> transformation? shape?)

(define shape-renderer?
  (-> (is-a?/c dc<%>) (listof procedure?)))

(define shape?
  (-> transformation? shape-renderer?))

(define shape-constructor?
  (->* () () #:rest (listof transformation?) shape?))

; Shape constructors

(define (make-square . shape-trans) ; shape constructor
  (λ (curr-trans) ; shape
    (let* ([trans (apply combine-transformation (cons curr-trans shape-trans))]
           [geom (transformation-geometric trans)]
           [a (matrix* geom (col-matrix [-0.5 -0.5 1]))]
           [b (matrix* geom (col-matrix [-0.5  0.5 1]))]
           [c (matrix* geom (col-matrix [ 0.5  0.5 1]))]
           [d (matrix* geom (col-matrix [ 0.5 -0.5 1]))]
           [points (list (cons (matrix-ref a 0 0) (matrix-ref a 1 0))
                         (cons (matrix-ref b 0 0) (matrix-ref b 1 0))
                         (cons (matrix-ref c 0 0) (matrix-ref c 1 0))
                         (cons (matrix-ref d 0 0) (matrix-ref d 1 0)))])
      (λ (dc) ; shape-renderer
        ; TODO: apply color transformation
        (send dc draw-polygon points)
        '()))))

(define (make-circle . shape-trans) ; shape constructor
  (λ (curr-trans) ; shape
    (let* ([trans (apply combine-transformation (cons curr-trans shape-trans))]
           [geom (transformation-geometric trans)]
           [orig (matrix* geom (col-matrix [0 0 1]))]
           [start (matrix* geom (col-matrix [1 0 1]))]
           [path (new dc-path%)])

      ; TODO: apply color transformation
      (send path move-to
            (matrix-ref start 0 0)
            (matrix-ref start 1 0))
      (for ([a (range -0.1 (* 2 pi) 0.1)])
        (let ([p (matrix* geom (col-matrix ((cos a) (sin a) 1)))])
          (send path line-to
                (matrix-ref p 0 0)
                (matrix-ref p 1 0))))
      (λ (dc) ; shape-renderer
        (send dc draw-path path)
        '()))))

; Helper to create shape constructors

; shortcut for defining a shape union constructor with arguments and bind it to name
; TODO: variant of define-shape that doesnt have arguments (not procedure)
(define-syntax-rule (define-shape (name arg ...) shape ...)
  (define (name arg ...)
    (union (list shape ...))))

; define a shape which is a union of one or more shapes
(define-syntax-rule (union shape-list)
  (λ shape-trans  ; shape-constructor
    (λ (curr-trans) ; shape
      (λ (dc) ; shape-renderer
        (let* ([t (apply combine-transformation (cons curr-trans shape-trans))] ; combine its transformation with current transformation into T
               [renderers (map (λ (s) (s t)) shape-list)]) ; list of shape-renderers, from list of shapes applied to T
          renderers)))))

(define-syntax-rule (define-shape-prob (name arg ...) (prob shape) ...)
  ; TODO: implement shape selector based on chance where "prob" is the
  ; probability of picking that specific shape
  (error "not implemented"))

; evaluate shape union body in a for loop and then union all together
(define-syntax-rule (loop-shape (for-clause ...) shape ...)
  (union (for/list (for-clause ...)
           ((union (list shape ...))))))

; Render a shape in a device context
; render-shape: (-> shape? (is-a?/c dc<%>))
(define (render-shape shape dc)
  (send dc set-pen "black" 0 'transparent)
  (send dc set-brush "black" 'solid)
  
  (let ([renderers-queue (make-queue)])
    (enqueue! renderers-queue (shape (identity)))
    (let render-loop ([renderer (dequeue! renderers-queue)]
                      [n 0])
      (for ([r (renderer dc)])
        (enqueue! renderers-queue r))
      (when (and (not (queue-empty? renderers-queue))
                 (<= n (maximum-render-cycles)))
        (render-loop (dequeue! renderers-queue) (+ 1 n))))))

;; ------------------------------------------------------------------------

(module+ test
  ;; # Tests
  (require rackunit)

  (define (random-real min max)
    (+ (/ (random (* (- max min) 10000)) 10000) min))

  (define (random-transformation)
    (transformation (matrix [[(random-real -1 1) (random-real -1 1) (random-real -1 1)]
                             [(random-real 0 1) (random-real -1 1) (random-real -1 1)]
                             [(random-real 0 1) (random-real -1 1) (random-real -1 1)]])
                    (vector (random-real -1 1) (random-real -1 1) (random-real -1 1))))

  ;; ## Geometric transformation tests

  ;; ### combining with identity is innocuous

  (define R (random-transformation))
  (check-equal? (combine-transformation (identity) R) R "transformation identity property (1)")
  (check-equal? (combine-transformation R (identity)) R "transformation identity property (2)")

  ;; ### Test invert operations
  
  (define x (random-real -100 100))
  (define y (random-real -100 100))
  
  (check-equal? (combine-transformation (translate x y) (translate (- x) (- y))) (identity) "translate invert property")
  (check-true (matrix= (transformation-geometric (combine-transformation (rotate x) (rotate (- x))))
                       (transformation-geometric (identity)))
              "rotate invert property")

  (when (not (or (= x 0) (= y 0)))
    (check-equal? (combine-transformation (scale x y) (scale (/ 1 x) (/ 1 y))) (identity) "rotate invert property"))

  ;;; ### Null operations

  (check-equal? (translate 0 0) (identity) "translate zero is identity")
  (check-equal? (rotate 0) (identity) "rotate zero is identity")
  (check-equal? (scale 1 1) (identity) "scale one is identity")
  )
