(in-package #:cl-hamt)

(defclass set-leaf (leaf) ())

(defclass set-conflict (conflict) ())
(defclass set-table (table) ())



;; Methods for looking up whether items are contained in the set
(defmethod %hamt-lookup ((node set-leaf) key hash depth test)
  (declare (ignore hash depth))
  (funcall test (node-key node) key))

(defmethod %hamt-lookup ((node set-table) key hash depth test)
  (with-table node hash depth
      (bitmap array bits index hit)
    (when hit
      (%hamt-lookup (aref array index) key hash (1+ depth) test))))

(defmethod %hamt-lookup ((node set-conflict) key hash depth test)
  (declare (ignore hash depth))
  (member key (conflict-entries node) :test test))



;; Methods for inserting items into the set
(defgeneric %set-insert (node key hash depth test))

;; Adding a new element to a leaf node either returns the leaf node if that
;; item was already present in the set, or creates a conflict node if there
;; was a hash collision.
(defmethod %set-insert ((node set-leaf) key hash depth test)
  (declare (ignore depth))
  (let ((nkey (node-key node)))
    (if (funcall test key nkey)
        node
        (make-instance 'set-conflict
                       :hash hash
                       :entries (list key nkey)))))

(defmethod %set-insert ((node set-conflict) key hash depth test)
  (let ((entries (conflict-entries node)))
    (make-instance 'set-conflict
                   :hash hash
                   :entries (if (member key entries :test test)
                                entries
                                (cons key entries)))))

(defmethod %set-insert ((node set-table) key hash depth test)
  (with-table node hash depth
      (bitmap array bits index hit)
    (flet ((%insert (table)
             (%set-insert table key hash (1+ depth) test)))
      (let ((new-node
              (cond
                (hit (%insert (aref array index)))
                ((= depth 6) (make-instance 'set-leaf :key key))
                (t (%insert (make-instance 'set-table))))))
        (make-instance 'set-table
                       :bitmap (logior bitmap (ash 1 bits))
                       :table (funcall (if hit #'vec-update #'vec-insert)
                                       array
                                       index
                                       new-node))))))



;; Methods for removing items from a hash-set
(defmethod %hamt-remove ((node set-conflict) key hash depth test)
  (let ((entries (remove key (conflict-entries node) :test test)))
    (if (= (length entries) 1)
        (make-instance 'set-leaf
                       :key (car entries))
        (make-instance 'set-conflict
                       :hash hash
                       :entries entries))))



;; Methods for reducing over elements of hash-sets
(defmethod %hamt-reduce (func (node set-leaf) initial-value)
  (funcall func initial-value (node-key node)))

(defmethod %hamt-reduce (func (node set-conflict) initial-value)
  (reduce func (conflict-entries node) :initial-value initial-value))



;; Wrapper set class
(defclass hash-set (hamt)
  ((table
    :reader hamt-table
    :initarg :table
    :initform (make-instance 'set-table
                             :bitmap 0
                             :table (make-array 0)))))

(defun empty-set (&key (test #'equal) (hash #'cl-murmurhash:murmurhash))
  "Return an empty hash-set, in which elements will be compared and hashed
with the supplied test and hash functions. The hash must be a 32-bit hash."
  (make-instance 'hash-set :test test :hash hash))

(defun set-lookup (set x)
  "Return true if the object x is in the set, false otherwise"
  (with-hamt set (:test test :hash hash :table table)
    (%hamt-lookup table x (funcall hash x) 0 test)))

(defun set-size (set)
  "Return the size of the set"
  (%hamt-size (hamt-table set)))

(defun set-insert (set &rest xs)
  "Return a new set with the elements xs added to it. Elements already in
the set are ignored."
  (with-hamt set (:test test :hash hash :table table)
    (flet ((%insert (table x)
             (%set-insert table x (funcall hash x) 0 test)))
      (make-instance 'hash-set
                     :test test
                     :hash hash
                     :table (reduce #'%insert xs :initial-value table)))))

(defun set-remove (set &rest xs)
  "Return a new set with the elements xs removed from it. If an item x in
xs is not in the set, it is ignored."
  (with-hamt set (:test test :hash hash :table table)
    (flet ((%remove (table x)
             (%hamt-remove table x (funcall hash x) 0 test)))
      (make-instance 'hash-set
                     :test test
                     :hash hash
                     :table (reduce #'%remove xs :initial-value table)))))

(defun set-reduce (func set initial-value)
  "Successively apply a function to elements of the set. The function is
assumed to have the signature
  `func :: A B -> A`,
where A is the type of `initial-value` and `B` is the type of set elements.
Note that HAMTs do not store items in any order, so the reduction operation
cannot be sensitive to the order in which the items are reduced."
  (%hamt-reduce func (hamt-table set) initial-value))

(defun set-map (func set
                &key
                  (test nil test-supplied-p)
                  (hash nil hash-supplied-p))
  "Return the image of a set under a given function. Optionally use new
comparison and hash functions for the mapped set."
  (set-reduce (lambda (mapped-set x)
                (set-insert mapped-set
                            (funcall func x)))
              set
              (empty-set :test (if test-supplied-p test (hamt-test set))
                         :hash (if hash-supplied-p hash (hamt-hash set)))))

(defun set-filter (predicate set)
  "Return the elements of the set satisfying a given predicate."
  (set-reduce (lambda (filtered-set x)
                (if (funcall predicate x)
                    (set-insert filtered-set x)
                    filtered-set))
              set
              (empty-set :test (hamt-test set)
                         :hash (hamt-hash set))))

(defun set->list (set)
  (set-reduce (lambda (lst x) (cons x lst))
              set
              '()))

(defun set-union (set &rest args)
  (reduce (lambda (set1 set2)
            (set-reduce #'set-insert set1 set2))
          args :initial-value set))

(defun set-intersection (set &rest args)
  (reduce (lambda (set1 set2)
            (set-filter (lambda (x) (set-lookup set1 x)) set2))
          args :initial-value set))

(defun set-diff (set &rest args)
  (reduce (lambda (set1 set2)
            (set-reduce #'set-remove set2 set1))
          args :initial-value set))

(defun set-symmetric-diff (set1 set2)
  (set-diff (set-union set1 set2)
            (set-intersection set1 set2)))


;; Methods for deciding if two sets are equal
(defgeneric %hash-set-eq (set1 set2 test))

(defmethod %hash-set-eq (node1 node2 test)
  (declare (ignore node1 node2 test))
  nil)

(defmethod %hash-set-eq ((node1 set-leaf) (node2 set-leaf) test)
  (funcall test (node-key node1) (node-key node2)))

(defmethod %hash-set-eq ((node1 set-conflict) (node2 set-conflict) test)
  (and (equal (conflict-hash node1) (conflict-hash node2))
       (tree-equal (conflict-entries node1) (conflict-entries node2) :test test)))

(defmethod %hash-set-eq ((node1 set-table) (node2 set-table) test)
  (and (equal (table-bitmap node1) (table-bitmap node2))
       (array-eq (table-array node1)
                 (table-array node2)
                 (lambda (set1 set2)
                   (%hash-set-eq set1 set2 test)))))

(defun set-eq (set1 set2)
  (let ((test1 (hamt-test set1)))
    (if (not (eq test1 (hamt-test set2)))
        (error 'incompatible-tests-error)
        (%hash-set-eq (hamt-table set1) (hamt-table set2) test1))))
