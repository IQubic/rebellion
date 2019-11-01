#lang racket/base

(module+ test
  (require rackunit
           rebellion/base/immutable-string
           rebellion/collection/list
           rebellion/private/static-name
           rebellion/streaming/reducer
           rebellion/streaming/transducer))

(module+ test
  (test-case (name-string transducer-pipe)
    (test-case "zero transducers"
      (define piped (transducer-pipe))
      (check-equal? (transduce "hello" piped #:into into-string) "hello")
      (check-equal? (transduce (in-naturals) piped (taking 5) #:into into-list)
                    (list 0 1 2 3 4)))
    
    (test-case "one transducer"
      (define piped (transducer-pipe (taking 3)))
      (check-equal? (transduce "hello" piped #:into into-string) "hel")
      (check-equal? (transduce (in-naturals) piped #:into into-list)
                    (list 0 1 2))
      (check-equal? (transduce (list 0 1) piped #:into into-list) (list 0 1)))
    
    (test-case "two transducers"
      (define piped
        (transducer-pipe (filtering even?) (mapping number->immutable-string)))
      (check-equal?
       (transduce (in-range 0 10) piped #:into (join-into-string ","))
       "0,2,4,6,8"))

    (test-case "many transducers"
      (define piped
        (transducer-pipe (filtering even?)
                         (mapping (λ (x) (* x x)))
                         (taking 10)
                         (mapping -)
                         (append-mapping number->immutable-string)))
      (define inputs (in-naturals))
      (define expected "0-4-16-36-64-100-144-196-256-324")
      (check-equal? (transduce inputs piped #:into into-string) expected))))