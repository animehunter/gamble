;; Copyright (c) 2014 Ryan Culpepper
;; Released under the terms of the 2-clause BSD license.
;; See the file COPYRIGHT for details.

#lang racket/base
(require racket/vector
         math/flonum
         (prefix-in m: math/distributions)
         "dist.rkt")
(provide (all-defined-out))

;; Contains functions (pdf, cdf, inv-cdf, sample) used to implement
;; dists in gamble/dist. The naming convention is peculiar to the
;; define-dist-type macro (see gamble/dist).

(define-syntax-rule (define-memoize1 (fun arg) . body)
  (begin (define memo-table (make-weak-hash))
         (define (fun arg)
           (cond [(hash-ref memo-table arg #f)
                  => values]
                 [else
                  (define r (let () . body))
                  (hash-set! memo-table arg r)
                  r]))))


;; ============================================================
;; Drift Kernel Utils

(define (sample-normal mean stddev)
  (let ([mean (exact->inexact mean)]
        [stddev (exact->inexact stddev)])
    (flvector-ref (m:flnormal-sample mean stddev 1) 0)))

(define (drift:add-normal value scale)
  (cons (sample-normal value scale) 0))

(define (drift:mult-exp-normal value scale)
  ;; Want to multiply by factor log-normally distributed, with stddev proportional
  ;; to scale. For log-normal, variance = (exp[s^2] - 1)(exp[s^2]).
  ;; Let's approximate as exp[2s^2] - 1. So we want
  ;; exp[2s^2] - 1 ~= scale^2, so
  ;; s ~= sqrt(log(scale^2 + 1))    -- dropped a factor of 2, nuisance
  ;;
  ;; This process is equiv to value* ~ exp[ N(log(value), s) ]
  ;; So q(->) = N(log(value*); log(value), s) * 1/value*
  ;;    q(<-) = N(log(value); log(value*), s) * 1/value
  ;; So R-F = log(1/value) - log(1/value*)
  ;;        = log(value*) - log(value)
  (define sn (sample-normal 0 (sqrt (log (add1 (* scale scale))))))
  (define value* (* value (exp sn)))
  (when (eqv? value* +nan.0)
    (eprintf "value = ~s, scale = ~s, sn = ~s\n" value scale sn))
  (cons value* (- (log value*) (log value))))

;; Rounds away from zero to force different value. Note that this does
;; not agree with the typical accompanying drift-dist, which allows
;; zero. But that's okay; they don't need to agree.
(define (drift:add-discrete-normal value0 scale0 lo0 hi0)
  (define value (exact->inexact value0))
  (define scale (exact->inexact scale0))
  (define lo (exact->inexact lo0))
  (define hi (exact->inexact hi0))
  (define (discrete-normal-sample mean stddev)
    (let loop ()
      (define s (flvector-ref (m:flnormal-sample 0.0 stddev 1) 0))
      (define s* (+ mean (round-from-zero s)))
      (if (<= lo s* hi)
          s*
          (loop))))
  (define (discrete-normal-log-pdf mean stddev x)
    ;; FIXME: should really be using difference of unrounded cdfs instead of pdf
    (- (m:flnormal-pdf mean stddev x #t)
       (log (- (discrete-normal-cdf mean stddev hi)
               (discrete-normal-cdf mean stddev lo)))))
  (define (discrete-normal-cdf mean stddev x) ;; FIXME: logspace?
    (m:flnormal-cdf (exact->inexact mean) (exact->inexact stddev)
                    (exact->inexact (round-from-zero x)) #f #f))
  (define value* (discrete-normal-sample value scale))
  (define R (discrete-normal-log-pdf value* scale value))
  (define F (discrete-normal-log-pdf value scale value*))
  (cons (inexact->exact value*) (- R F)))

;; ============================================================
;; Utils

(define (round-from-zero x) (if (> x 0) (ceiling x) (floor x)))

(define (validate/normalize-weights who weights)
  (unless (and (vector? weights)
               (for/and ([w (in-vector weights)])
                 (and (rational? w) (>= w 0))))
    (raise-argument-error who "(vectorof (>=/c 0))" weights))
  (define weight-sum (for/sum ([w (in-vector weights)]) w))
  (unless (> weight-sum 0)
    (error who "weights sum to zero\n  weights: ~e" weights))
  (if (= weight-sum 1)
      (vector->immutable-vector weights)
      (vector-map (lambda (w) (/ w weight-sum)) weights)))

(define (unconvert-p p log? 1-p?)
  (define p* (if log? (exp p) p))
  (if 1-p? (- 1 p*) p*))

(define (convert-p p log? 1-p?)
  (define p* (if 1-p? (- 1 p) p))
  (if log? (log (exact->inexact p*)) p*))

(define (filter-modes f ms)
  (define-values (best best-p)
    (for/fold ([best null] [best-p -inf.0])
        ([m (in-list ms)])
      (define m-p (f m))
      (cond [(> m-p best-p)
             (values (list m) m-p)]
            [(= m-p best-p)
             (values (cons m best) best-p)]
            [else
             (values best best-p)])))
  (reverse best))

(define (vector-sum v) (for/sum ([x (in-vector v)]) x))

;; use in pdf functions instead of raising type (or other) error
(define (impossible log? who reason)
  ;; FIXME: may be useful to log occurrences of these
  (if log? -inf.0 0))
