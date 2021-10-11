#lang racket/base


(require racket/contract/base)


(provide
 (contract-out
  [persistent-red-black-tree? predicate/c]
  [in-persistent-red-black-tree
   (->* (persistent-red-black-tree?) (#:descending? boolean?) (sequence/c any/c))]
  [in-persistent-red-black-subtree
   (->* (persistent-red-black-tree? range?) (#:descending? boolean?) (sequence/c any/c))]
  [empty-persistent-red-black-tree (-> comparator? persistent-red-black-tree?)]
  [persistent-red-black-tree-size (-> persistent-red-black-tree? natural?)]
  [persistent-red-black-tree-comparator (-> persistent-red-black-tree? comparator?)]
  [persistent-red-black-tree-contains? (-> persistent-red-black-tree? any/c boolean?)]
  [persistent-red-black-tree-insert (-> persistent-red-black-tree? any/c persistent-red-black-tree?)]
  [persistent-red-black-tree-remove (-> persistent-red-black-tree? any/c persistent-red-black-tree?)]
  [persistent-red-black-tree-elements (-> persistent-red-black-tree? list?)]
  [persistent-red-black-tree-least-element (-> persistent-red-black-tree? option?)]
  [persistent-red-black-tree-greatest-element (-> persistent-red-black-tree? option?)]
  [persistent-red-black-tree-element-greater-than (-> persistent-red-black-tree? any/c option?)]
  [persistent-red-black-tree-element-less-than (-> persistent-red-black-tree? any/c option?)]
  [persistent-red-black-tree-element-at-most (-> persistent-red-black-tree? any/c option?)]
  [persistent-red-black-tree-element-at-least (-> persistent-red-black-tree? any/c option?)]
  [persistent-red-black-tree-binary-search
   (-> persistent-red-black-tree? any/c (or/c position? gap?))]
  [persistent-red-black-tree-binary-search-cut
   (-> persistent-red-black-tree? cut? (or/c position? gap?))]
  [persistent-red-black-subtree-copy
   (-> persistent-red-black-tree? range? persistent-red-black-tree?)]
  [persistent-red-black-subtree-size (-> persistent-red-black-tree? range? natural?)]
  [persistent-red-black-subtree-contains? (-> persistent-red-black-tree? range? any/c boolean?)]
  [sorted-unique-sequence->persistent-red-black-tree
   (-> (sequence/c any/c) comparator? persistent-red-black-tree?)]))


(require (for-syntax racket/base
                     syntax/parse)
         racket/contract/combinator
         racket/match
         racket/math
         racket/pretty
         racket/sequence
         racket/stream
         rebellion/base/comparator
         rebellion/base/option
         rebellion/base/range
         (submod rebellion/base/range private-for-rebellion-only)
         rebellion/collection/private/vector-binary-search
         rebellion/private/cut
         rebellion/private/guarded-block
         rebellion/private/static-name)


(module+ test
  (require (submod "..")
           rackunit))


;@----------------------------------------------------------------------------------------------------
;; Immutable persistent red-black trees (Okasaki's implementation)


;; We use constants for the red/black color enum instead of define-enum-type to avoid unnecessary
;; dependencies on other parts of Rebellion, especially cyclic dependencies. We define constants
;; instead of using the symbols directly so that typos are compile-time errors.
(define red 'red)
(define black 'black)


;; To implement deletion, we allow the tree to temporarily contain "double black" nodes and leaves
;; while rebalancing the tree after removing an element. This approach is based on the one outlined in
;; the "Deletion: The curse of the red-black tree" Functional Pearl paper. Link below:
;; https://matt.might.net/papers/germane2014deletion.pdf
(define double-black 'double-black)


(define black-leaf 'black-leaf)
(define double-black-leaf 'double-black-leaf)


(struct persistent-red-black-node
  (color left-child element right-child size)
  #:constructor-name constructor:persistent-red-black-node)


(define (singleton-red-black-node element)
  (constructor:persistent-red-black-node red black-leaf element black-leaf 1))


(define (make-red-black-node color left element right)
  (define children-size
    (cond
      [(and (persistent-red-black-node? left) (persistent-red-black-node? right))
       (+ (persistent-red-black-node-size left) (persistent-red-black-node-size right))]
      [(persistent-red-black-node? left) (persistent-red-black-node-size left)]
      [(persistent-red-black-node? right) (persistent-red-black-node-size right)]
      [else 0]))
  (constructor:persistent-red-black-node color left element right (add1 children-size)))


(define (make-red-node left element right)
  (make-red-black-node red left element right))


(define (make-black-node left element right)
  (make-red-black-node black left element right))


(define (make-double-black-node left element right)
  (make-red-black-node double-black left element right))


(define-match-expander red-node
  (syntax-parser
    [(_ left element right size)
     #'(persistent-red-black-node (== red) left element right size)])
  (make-rename-transformer #'make-red-node))


(define-match-expander black-node
  (syntax-parser
    [(_ left element right size)
     #'(persistent-red-black-node (== black) left element right size)])
  (make-rename-transformer #'make-black-node))


(define-match-expander double-black-node
  (syntax-parser
    [(_ left element right size)
     #'(persistent-red-black-node (== double-black) left element right size)])
  (make-rename-transformer #'make-double-black-node))


(define (red-node? v)
  (and (persistent-red-black-node? v) (equal? (persistent-red-black-node-color v) red)))


(define (black-node? v)
  (or (equal? v black-leaf)
      (and (persistent-red-black-node? v) (equal? (persistent-red-black-node-color v) black))))


(define (double-black-node? v)
  (or (equal? v double-black-leaf)
      (and (persistent-red-black-node? v) (equal? (persistent-red-black-node-color v) double-black))))


(struct persistent-red-black-tree
  (comparator root-node)
  #:guard (struct-guard/c comparator? (or/c persistent-red-black-node? black-leaf))
  #:constructor-name constructor:persistent-red-black-tree)


;; Construction


(define (empty-persistent-red-black-tree comparator)
  (constructor:persistent-red-black-tree comparator black-leaf))


(define (sorted-unique-sequence->persistent-red-black-tree elements comparator)
  ;; TODO
  (empty-persistent-red-black-tree comparator))


(define/guard (persistent-red-black-subtree-copy tree range)
  (guard-match (present least) (persistent-red-black-tree-least-element tree) else
    (empty-persistent-red-black-tree (persistent-red-black-tree-comparator tree)))
  (match-define (present greatest) (persistent-red-black-tree-greatest-element tree))
  (guard (and (range-contains? range least) (range-contains? range greatest)) then
    tree)
  (for/fold ([tree (empty-persistent-red-black-tree (persistent-red-black-tree-comparator tree))])
            ([element (in-persistent-red-black-subtree tree range)])
    (persistent-red-black-tree-insert tree element)))


;; Iteration


(define (in-persistent-red-black-tree tree #:descending? [descending? #false])
  
  (define in-node
    (if descending?
        (λ (node)
          (if (persistent-red-black-node? node)
              (sequence-append
               (in-node (persistent-red-black-node-right-child node))
               (stream (persistent-red-black-node-element node))
               (in-node (persistent-red-black-node-left-child node)))
              (stream)))
        (λ (node)
          (if (persistent-red-black-node? node)
              (sequence-append
               (in-node (persistent-red-black-node-left-child node))
               (stream (persistent-red-black-node-element node))
               (in-node (persistent-red-black-node-right-child node)))
              (stream)))))
  
  (stream* (in-node (persistent-red-black-tree-root-node tree))))


(define (in-persistent-red-black-subtree tree range #:descending? [descending? #false])

  (define/guard (in-ascending-node node)
    (guard (persistent-red-black-node? node) else
      (stream))
    (define element (persistent-red-black-node-element node))
    (match (range-compare-to-value range element)
      [(== lesser) (in-ascending-node (persistent-red-black-node-right-child node))]
      [(== greater) (in-ascending-node (persistent-red-black-node-left-child node))]
      [(== equivalent)
       (sequence-append
        (in-ascending-node (persistent-red-black-node-right-child node))
        (stream element)
        (in-ascending-node (persistent-red-black-node-left-child node)))]))

  (define/guard (in-descending-node node)
    (guard (persistent-red-black-node? node) else
      (stream))
    (define element (persistent-red-black-node-element node))
    (match (range-compare-to-value range element)
      [(== lesser) (in-descending-node (persistent-red-black-node-right-child node))]
      [(== greater) (in-descending-node (persistent-red-black-node-left-child node))]
      [(== equivalent)
       (sequence-append
        (in-descending-node (persistent-red-black-node-left-child node))
        (stream element)
        (in-descending-node (persistent-red-black-node-right-child node)))]))

  (define root (persistent-red-black-tree-root-node tree))
  (if descending? (stream* (in-descending-node root)) (stream* (in-ascending-node root))))


;; Queries and searching


(define (persistent-red-black-tree-size tree)
  (define root (persistent-red-black-tree-root-node tree))
  (if (persistent-red-black-node? root) (persistent-red-black-node-size root) 0))


(define/guard (persistent-red-black-tree-contains? tree element)
  (define cmp (persistent-red-black-tree-comparator tree))

  (define/guard (loop [node (persistent-red-black-tree-root-node tree)])
    (guard (persistent-red-black-node? node) else
      #false)
    (match-define (persistent-red-black-node _ left node-element right _) node)
    (match (compare cmp node-element element)
      [(== lesser) (loop right)]
      [(== greater) (loop left)]
      [(== equivalent) #true]))
  
  (and (contract-first-order-passes? (comparator-operand-contract cmp) element) (loop)))


(define (persistent-red-black-subtree-contains? tree range element)
  (and (range-contains? range element) (persistent-red-black-tree-contains? tree element)))


(define (persistent-red-black-tree-generalized-binary-search tree search-function)

  (define/guard (loop [node (persistent-red-black-tree-root-node tree)]
                      [min-start-index 0]
                      [lower-element absent]
                      [upper-element absent])
    (guard-match (persistent-red-black-node _ left element right _) node else
      (gap min-start-index lower-element upper-element))
    (match (search-function element)
      [(== lesser)
       (define left-size (if left (persistent-red-black-node-size left) 0))
       (loop right (+ min-start-index left-size 1) (present element) upper-element)]
      [(== greater)
       (loop left min-start-index lower-element (present element))]
      [(== equivalent)
       (define left-size (if left (persistent-red-black-node-size left) 0))
       (position (+ min-start-index left-size) element)]))

  (loop))


(define (persistent-red-black-tree-binary-search tree element)
  (define cmp (persistent-red-black-tree-comparator tree))
  (persistent-red-black-tree-generalized-binary-search tree (λ (x) (compare cmp x element))))


(define (persistent-red-black-tree-binary-search-cut tree cut)
  (define cut-cmp (cut<=> (persistent-red-black-tree-comparator tree)))
  (persistent-red-black-tree-generalized-binary-search
   tree (λ (c) (compare cut-cmp (middle-cut c) cut))))


(define (persistent-red-black-subtree-size tree range)
  (define lower (range-lower-cut range))
  (define upper (range-upper-cut range))
  (- (gap-index (persistent-red-black-tree-binary-search-cut tree upper))
     (gap-index (persistent-red-black-tree-binary-search-cut tree lower))))


(define (persistent-red-black-tree-elements tree)
  (sequence->list (in-persistent-red-black-tree tree)))


(define/guard (persistent-red-black-tree-least-element tree)
  (define root (persistent-red-black-tree-root-node tree))
  (guard (persistent-red-black-node? root) else
    absent)
  
  (define (loop node)
    (match (persistent-red-black-node-left-child node)
      [(== black-leaf) (persistent-red-black-node-element node)]
      [left-child (loop left-child)]))

  (present (loop root)))


(define/guard (persistent-red-black-tree-greatest-element tree)
  (define root (persistent-red-black-tree-root-node tree))
  (guard (persistent-red-black-node? root) else
    absent)
  
  (define (loop node)
    (match (persistent-red-black-node-right-child node)
      [(== black-leaf) (persistent-red-black-node-element node)]
      [right-child (loop right-child)]))

  (present (loop root)))


(define (persistent-red-black-tree-element-less-than tree upper-bound)
  (gap-element-before (persistent-red-black-tree-binary-search-cut tree (lower-cut upper-bound))))


(define (persistent-red-black-tree-element-greater-than tree lower-bound)
  (gap-element-after (persistent-red-black-tree-binary-search-cut tree (upper-cut lower-bound))))


(define (persistent-red-black-tree-element-at-most tree upper-bound)
  (match (persistent-red-black-tree-binary-search tree upper-bound)
    [(position _ equivalent-element) (present equivalent-element)]
    [(gap _ lesser-element _) lesser-element]))


(define (persistent-red-black-tree-element-at-least tree lower-bound)
  (match (persistent-red-black-tree-binary-search tree lower-bound)
    [(position _ equivalent-element) (present equivalent-element)]
    [(gap _ _ greater-element) greater-element]))


;; Modification


(define (persistent-red-black-tree-insert tree element)
  (define element<=> (persistent-red-black-tree-comparator tree))
  (define root (persistent-red-black-tree-root-node tree))
  
  (define/guard (loop node)
    (guard (persistent-red-black-node? node) else
      (singleton-red-black-node element))
    (define node-element (persistent-red-black-node-element node))
    (match (compare element<=> element node-element)
      [(== equivalent) node]
      
      [(== lesser)
       (define new-node
         (make-red-black-node
          (persistent-red-black-node-color node)
          (loop (persistent-red-black-node-left-child node))
          (persistent-red-black-node-element node)
          (persistent-red-black-node-right-child node)))
       (balance new-node)]
      
      [(== greater)
       (define new-node
         (make-red-black-node
          (persistent-red-black-node-color node)
          (persistent-red-black-node-left-child node)
          (persistent-red-black-node-element node)
          (loop (persistent-red-black-node-right-child node))))
       (balance new-node)]))
  
  (constructor:persistent-red-black-tree element<=> (loop (blacken root))))


(define (persistent-red-black-tree-remove tree element)
  (define cmp (persistent-red-black-tree-comparator tree))
  (define (remove node)
    (match node

      [(== black-leaf) black-leaf]

      [(red-node (== black-leaf) x (== black-leaf) _)
       #:when (compare-infix cmp x == element)
       black-leaf]

      [(black-node (== black-leaf) x (== black-leaf) _)
       #:when (compare-infix cmp x == element)
       double-black-leaf]

      [(black-node (red-node left x right _) y (== black-leaf) _)
       #:when (compare-infix cmp y == element)
       (black-node left x right)]

      [(black-node (== black-leaf) x (red-node left y right _) _)
       #:when (compare-infix cmp x == element)
       (black-node left y right)]

      [(persistent-red-black-node color left x right size)
       (rotate
        (match (compare cmp element x)
          [(== lesser) (make-red-black-node color (remove left) x right)]
          [(== greater) (make-red-black-node color left x (remove right))]
          [(== equivalent)
           (with-handlers ([(λ (_) #true)
                            (λ (e)
                              (pretty-print tree)
                              (pretty-print node)
                              (raise e))])
             (define-values (new-x new-right) (min/delete right))
             (make-red-black-node color left new-x new-right))]))]))

  (define new-root (remove (redden (persistent-red-black-tree-root-node tree))))
  (constructor:persistent-red-black-tree cmp new-root))


(define (redden node)
  (match node
    [(black-node (? black-node? left) x (? black-node? right) _)
     (red-node left x right)]
    [_ node]))


(define (blacken node)
  (match node
    [(red-node left x right _)
     (black-node left x right)]
    [_ node]))


(define (min/delete node)
  (match node
    [(red-node (== black-leaf) x (== black-leaf) _) (values x black-leaf)]
    [(black-node (== black-leaf) x (== black-leaf) _) (values x double-black-leaf)]
    [(black-node (== black-leaf) x (red-node left y right _) _)
     (values x (black-node left y right))]
    [(persistent-red-black-node c left x right _)
     (define-values (v new-left) (min/delete left))
     (values v (rotate (make-red-black-node c new-left x right)))]))


(define (balance node)
  (match node
    [(or (black-node (red-node (red-node a x b _) y c _) z d _)
         (black-node (red-node a x (red-node b y c _) _) z d _)
         (black-node a x (red-node (red-node b y c _) z d _) _)
         (black-node a x (red-node b y (red-node c z d _) _) _))
     (red-node (black-node a x b) y (black-node c z d))]
    [(or (double-black-node (red-node a x (red-node b y c _) _) z d _)
         (double-black-node a x (red-node (red-node b y c _) z d _) _))
     (black-node (black-node a x b) y (black-node c z d))]
    [t t]))


(define (rotate node)
  (match node

    [(red-node (? double-black-node? a-x-b) y (black-node c z d _) _)
     (balance (black-node (red-node (remove-double-black a-x-b) y c) z d))]
    [(red-node (black-node a x b _) y (? double-black-node? c-z-d) _)
     (balance (black-node a x (red-node b y (remove-double-black c-z-d))))]
    
    [(black-node (? double-black-node? a-x-b) y (black-node c z d _) _)
     (balance (double-black-node (red-node (remove-double-black a-x-b) y c) z d))]
    [(black-node (black-node a x b _) y (? double-black-node? c-z-d) _)
     (balance (double-black-node a x (red-node b y (remove-double-black c-z-d))))]
    
    [(black-node (? double-black-node? a-w-b) x (red-node (black-node c y d _) z e _) _)
     (black-node (balance (black-node (red-node (remove-double-black a-w-b) x c) y d)) z e)]
    [(black-node (red-node a w (black-node b x c _) _) y (? double-black-node? d-z-e) _)
     (black-node a w (balance (black-node b x (red-node c y (remove-double-black d-z-e)))))]
    
    [t t]))


(define (remove-double-black node)
  (match node
    [(== double-black-leaf) black-leaf]
    [(double-black-node a x b _) (black-node a x b)]))


(module+ test
  
  (define empty-tree (empty-persistent-red-black-tree natural<=>))

  (define (tree-of . elements)
    (for/fold ([tree empty-tree])
              ([element (in-list elements)])
      (persistent-red-black-tree-insert tree element)))

  (define (remove-all tree . elements)
    (for/fold ([tree tree])
              ([element (in-list elements)])
      (persistent-red-black-tree-remove tree element)))
  
  (test-case (name-string persistent-red-black-tree-size)
    
    (test-case "empty trees"
      (check-equal? (persistent-red-black-tree-size empty-tree) 0))
    
    (test-case "singleton trees"
      (define tree (tree-of 5))
      (check-equal? (persistent-red-black-tree-size tree) 1))
    
    (test-case "trees with many elements"
      (define tree (tree-of 3 5 2 1 4))
      (check-equal? (persistent-red-black-tree-size tree) 5)))
  
  (test-case (name-string persistent-red-black-tree-insert)
    
    (test-case "insert one element into empty tree"
      (define tree (tree-of 5))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 5)))
    
    (test-case "insert two ascending elements into empty tree"
      (define tree (tree-of 5 10))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 5 10)))
    
    (test-case "insert two descending elements into empty tree"
      (define tree (tree-of 5 2))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 2 5)))
    
    (test-case "insert many ascending elements into empty tree"
      (define tree (tree-of 1 2 3 4 5))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4 5)))
    
    (test-case "insert many descending elements into empty tree"
      (define tree (tree-of 5 4 3 2 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4 5)))
    
    (test-case "insert ascending and descending elements into empty tree"
      (define tree (tree-of 2 3 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3)))
    
    (test-case "insert many ascending and descending elements into empty tree"
      (define tree (tree-of 3 5 1 4 2))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4 5)))
    
    (test-case "insert repeatedly ascending then descending elements into empty tree"
      (define tree (tree-of 1 7 2 6 3 5 4))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4 5 6 7)))
    
    (test-case "insert repeatedly descending then ascending elements into empty tree"
      (define tree (tree-of 7 1 6 2 5 3 4))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4 5 6 7)))
    
    (test-case "insert many ascending elements then many descending elements into empty tree"
      (define tree (tree-of 4 5 6 7 3 2 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4 5 6 7))))

  (test-case (name-string persistent-red-black-tree-remove)

    (test-case "remove from empty tree"
      (define tree (persistent-red-black-tree-remove (tree-of) 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list)))

    (test-case "remove contained from singleton tree"
      (define tree (persistent-red-black-tree-remove (tree-of 1) 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list)))

    (test-case "remove non-contained from singleton tree"
      (define tree (persistent-red-black-tree-remove (tree-of 1) 2))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1)))

    (test-case "remove min from tree with many elements"
      (define tree (persistent-red-black-tree-remove (tree-of 1 2 3 4 5) 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 2 3 4 5)))

    (test-case "remove max from tree with many elements"
      (define tree (persistent-red-black-tree-remove (tree-of 1 2 3 4 5) 5))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 3 4)))

    (test-case "remove middle from tree with many elements"
      (define tree (persistent-red-black-tree-remove (tree-of 1 2 3 4 5) 3))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2 4 5)))

    (test-case "remove lower half from tree with many elements in ascending order"
      (define tree (remove-all (tree-of 1 2 3 4 5) 1 2 3))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 4 5)))

    (test-case "remove lower half from tree with many elements in descending order"
      (define tree (remove-all (tree-of 1 2 3 4 5) 3 2 1))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 4 5)))

    (test-case "remove lower half from tree with many elements in alternating order"
      (define tree (remove-all (tree-of 1 2 3 4 5) 1 3 2))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 4 5)))

    (test-case "remove upper half from tree with many elements in ascending order"
      (define tree (remove-all (tree-of 1 2 3 4 5) 3 4 5))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2)))

    (test-case "remove upper half from tree with many elements in descending order"
      (define tree (remove-all (tree-of 1 2 3 4 5) 5 4 3))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2)))

    (test-case "remove upper half from tree with many elements in alternating order"
      (define tree (remove-all (tree-of 1 2 3 4 5) 3 5 4))
      (define elements (persistent-red-black-tree-elements tree))
      (check-equal? elements (list 1 2)))))