;; Copyright (c) 2014 Ryan Culpepper
;; Released under the terms of the 2-clause BSD license.
;; See the file COPYRIGHT for details.

#lang racket/base
(require (for-syntax racket/base
                     syntax/parse
                     syntax/parse/experimental/template
                     racket/syntax
                     syntax/name)
         (rename-in racket/match [match-define defmatch])
         racket/class
         "dist.rkt"
         "context.rkt"
         "prob-util.rkt"
         "prob-mh.rkt"
         "prob-enum.rkt"
         "interfaces.rkt")
(provide (except-out (all-defined-out) table table*)
         (rename-out [table* table]))

;; ----

(define-syntax (observe stx)
  (syntax-case stx ()
    [(observe e v)
     ;; Note: instrumenter uses 'observed-expr property to report error
     (with-syntax ([thunk (syntax-property #'(lambda () e) 'observe-form stx)])
       #'(observe* thunk v))]))

(define observe/fail
  ;; FIXME: turn 2nd case into observe with fail instead of error?
  ;; FIXME: then convert 1st case w/ =, equal?, etc into 2nd case
  (case-lambda
    [(v) (unless v (fail 'observation))]
    [(v1 v2) (unless (equal? v1 v2) (fail 'observation))]))

;; ----

(define-syntax (rejection-sampler stx)
  (syntax-parse stx
    [(rejection-query def:expr ... result:expr)
     (template
      (rejection-sampler*
       (lambda () def ... result)))]))

(define (rejection-sampler* thunk)
  (new rejection-sampler% (thunk thunk)))

(define rejection-sampler%
  (class sampler-base%
    (init-field thunk)
    (field [successes 0]
           [rejections 0])
    (super-new)

    (define/override (info)
      (printf "== Rejection sampler\n")
      (printf "Samples produced: ~s\n" successes)
      (printf "Rejections: ~s\n" rejections))

    (define/override (sample)
      (define ctx (new rejection-stochastic-ctx%))
      (define v (send ctx run thunk))
      (case (car v)
        [(okay)
         (set! successes (add1 successes))
         (cdr v)]
        [(fail)
         (set! rejections (add1 rejections))
         (sample)]))
    ))

(define rejection-stochastic-ctx%
  (class plain-stochastic-ctx/run%
    (inherit fail run)
    (super-new)
    (define/override (observe-sample dist val scale)
      (cond [(or (finite-dist? dist) (integer-dist? dist))
             ;; ie, actually have pmf
             (unless (< (random) (dist-pdf dist val))
               (fail 'observation))]
            [else
             (error 'observe-sample
                    (string-append 
                     "observation on distribution not supported by rejection sampler"
                     "\n  distribution: ~e")
                    dist)]))

    (define/public (trycatch p1 p2)
      (match (run p1)
        [(cons 'okay value)
         value]
        [(cons 'fail _)
         (p2)]))
    ))

;; ----

(define-syntax (importance-sampler stx)
  (syntax-parse stx
    [(importance-sampler def:expr ... result:expr)
     (template
      (importance-sampler*
       (lambda () def ... result)))]))

(define (importance-sampler* thunk)
  (new importance-sampler% (thunk thunk)))

(define importance-sampler%
  (class* object% (weighted-sampler<%>)
    (init-field thunk)
    (field [successes 0]
           [rejections 0]
           [dens-dim-rejections 0]
           [min-dens-dim +inf.0]
           [bad-samples 0])
    (super-new)

    (define/public (info)
      (printf "== Importance sampler\n")
      (printf "Samples produced: ~s\n" successes)
      (printf "Rejections: ~s\n" rejections)
      (printf "Density dimension: ~s\n" min-dens-dim)
      (unless (zero? dens-dim-rejections)
        (printf "Density dimension rejections: ~s\n" dens-dim-rejections))
      (unless (zero? bad-samples)
        (printf "Bad samples emitted (wrong density dimension): ~s" bad-samples)))

    (define/public (sample/weight)
      (define ctx (new importance-stochastic-ctx%))
      (define v (send ctx run thunk))
      (case (car v)
        [(okay)
         (define dens-dim (get-field dens-dim ctx))
         (when (< dens-dim min-dens-dim)
           (unless (zero? successes)
             (eprintf "WARNING: previous ~s samples are meaningless; wrong density dimension\n"
                      successes))
           (vprintf "Lower density dimension seen: ~s\n" dens-dim)
           (set! bad-samples successes)
           (set! min-dens-dim dens-dim))
         (cond [(<= dens-dim min-dens-dim)
                (set! successes (add1 successes))
                (cons (cdr v) (get-field weight ctx))]
               [else
                (set! dens-dim-rejections (add1 dens-dim-rejections))
                (set! rejections (add1 rejections))
                (sample/weight)])]
        [(fail)
         (set! rejections (add1 rejections))
         (sample/weight)]))
    ))

(define importance-stochastic-ctx%
  (class rejection-stochastic-ctx%
    (field [weight 1]
           [dens-dim 0])
    (inherit fail run)
    (super-new)
    (define/override (observe-sample dist val scale)
      (define l (dist-pdf dist val))
      (unless (dist-has-mass? dist) (set! dens-dim (add1 dens-dim)))
      (if (positive? l)
          (set! weight (* weight l scale))
          (fail 'observation)))

    (define/override (trycatch p1 p2)
      (define saved-weight weight)
      (define saved-dens-dim dens-dim)
      (match (run p1)
        [(cons 'okay value)
         value]
        [(cons 'fail _)
         (set! weight saved-weight)
         (set! dens-dim saved-dens-dim)
         (p2)]))
    ))

;; ----

(define-syntax (mh-sampler stx)
  (syntax-parse stx
    [(mh-sampler (~optional (~seq #:transition tx))
                 def:expr ... result:expr)
     #:declare tx (expr/c #'mh-transition?)
     (template
      (mh-sampler*
       (lambda () def ... result)
       (?? tx.c)))]))

;; ----

(define-syntax (enumerate stx)
  (syntax-parse stx
    [(enumerate (~or (~optional (~seq #:limit limit:expr))
                     (~optional (~seq #:normalize? normalize?)))
                ...
                def:expr ... result:expr)
     (template
      (enumerate*
       (lambda () def ... result)
       (?? limit #f)
       (?? normalize? #t)))]))

;; ----

(struct ppromise (thunk))

(define-syntax-rule (pdelay e ...)
  (ppromise (mem (lambda () e ...))))

(define (pforce pp)
  ((ppromise-thunk pp)))

(define-syntax (deflazy stx)
  (syntax-parse stx
    [(deflazy x:id e:expr)
     (with-syntax ([(xtmp) (generate-temporaries #'(x))]
                   [x (syntax-property #'x 'gamble:model:export-mode 'lazy)])
       #'(begin (define xtmp (mem (lambda () e)))
                (define-syntaxes (x)
                  (make-variable-like-transformer
                   #'(xtmp)))))]))

(define-syntax (defmem stx)
  (define-syntax-class formals
    (pattern (_:id ...))
    (pattern (_:id ... . _:id)))
  (syntax-parse stx
    [(defmem (f:id . frm:formals) body:expr ...+)
     #'(define f (mem (let ([f (lambda frm body ...)]) f)))]))

;; ----

(define-syntax-rule (label l e)
  (parameterize ((current-label l)) e))

;; ----

(define-syntax-rule (with-zone z e ...)
  (parameterize ((current-zones (cons z (current-zones)))) e ...))

;; ----

(begin-for-syntax
 (define-splicing-syntax-class maybe-lazy
   (pattern (~seq #:lazy)
            #:with wrap-body #'pdelay
            #:with lazy? #'#t)
   (pattern (~seq)
            #:with wrap-body #'begin
            #:with lazy? #'#f)))

(define table-none (gensym 'none))

(define-syntax (table* stx)
  (syntax-parse stx
    [(table ([x:id seq:expr] ...) l:maybe-lazy body:expr ...+)
     (with-syntax ([inferred-name (syntax-local-infer-name stx)])
       #'(let* ([h (for*/hash ([x seq] ...)
                     (values (vector x ...)
                             (l.wrap-body (let () body ...))))])
           (make-table h 'inferred-name (length '(x ...)) l.lazy?)))]
    [(table (x:id ...) body:expr ...+)
     (with-syntax ([inferred-name (syntax-local-infer-name stx)])
       #'(let ([inferred-name (lambda (x ...) body ...)])
           (make-memo-table (mem inferred-name) 'inferred-name)))]))

(define-struct table (h name arity lazy?)
  #:property prop:procedure
  (lambda (t . args)
    (let ([key (list->vector args)]
          [h (table-h t)])
      (let ([v (hash-ref h key table-none)])
        (cond [(eq? v table-none)
               (table-error t key)]
              [(table-lazy? t)
               (pforce v)]
              [else v]))))
  #:property prop:custom-write
  (lambda (t port mode)
    (write-string (format "#<table:~s>" (table-name t)) port)))

(define (table-error t key)
  (cond [(= (vector-length key) (table-arity t))
         (error (table-name t)
                "table has no value for given arguments\n  arguments: ~e"
                (vector->list key))]
        [else
         (apply raise-arity-error (table-name t) (table-arity t) (vector->list key))]))

;; FIXME: add operations on table, eg enumerate keys?

;; FIXME: recognize array cases, use more compact representation?

(define-struct memo-table (f name)
  #:property prop:procedure (struct-field-index f)
  #:property prop:custom-write
  (lambda (t port mode)
    (write-string (format "#<table:~s>" (memo-table-name t)) port)))