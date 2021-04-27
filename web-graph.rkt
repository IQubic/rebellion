#lang at-exp racket/base

(require racket/contract/base)

(provide
 (contract-out
  [empty-web-graph web-graph?]
  [web-graph (-> web-link? ... web-graph?)]
  [web-graph? (-> any/c boolean?)]))

(require racket/struct
         rebellion/type/tuple
         rebellion/web-link)

(module+ test
  (require (submod "..")
           racket/port
           racket/pretty
           rackunit
           rebellion/private/at-exp-string-builders))

;@------------------------------------------------------------------------------

(define (property-maker descriptor)
  (define name (tuple-type-name (tuple-descriptor-type descriptor)))
  (define accessor (tuple-descriptor-accessor descriptor))
  (define equal+hash (default-tuple-equal+hash descriptor))
  (define custom-write
    (make-constructor-style-printer
     (λ (_) name)
     (λ (this) (accessor this 0))))
  (list (cons prop:equal+hash equal+hash)
        (cons prop:custom-write custom-write)))

(define-tuple-type web-graph (links)
  #:property-maker property-maker
  #:omit-root-binding)

(define (web-graph . links)
  (constructor:web-graph links))

(define empty-web-graph (web-graph))

(module+ test
  (test-case "custom-write"
    (define graph
      (web-graph
       (web-link "http://example.org" 'stylesheet "/styles.css")
       (web-link "http://example.org" 'stylesheet "/fonts.css")
       (web-link "http://example.org" 'search "/opensearch.xml")
       (web-link "http://example.org" 'privacy-policy "/privacy-policy")))
    (define (~pretty v #:columns columns)
      (parameterize ([pretty-print-columns columns])
        (with-output-to-string
          (λ () (pretty-print v)))))
    (define expected
      @block-string{
        (web-graph
          (web-link "http://example.org" 'stylesheet "/styles.css")
          (web-link "http://example.org" 'stylesheet "/fonts.css")
          (web-link "http://example.org" 'search "/opensearch.xml")
          (web-link "http://example.org" 'privacy-policy "/privacy-policy"))})
    (check-equal? (~pretty graph #:columns 80) expected)))
