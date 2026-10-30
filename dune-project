(lang dune 3.0)

(name ren)

(package
 (name ren)
 (synopsis "The Ren programming language")
 (depends
  (ocaml (>= 5.5))
  (dune (>= 3.24))
  (ppx_deriving (>= 6.2))
  (ppx_expect (= v0.17.3))))
