{-
  A first example in equalional reasoning. 
  From the definition of append we should be able to 
  semi-automatically prove the three axioms.
 -}

{- LIQUID "--newcheck" @-}
{-@ LIQUID "--no-termination" @-}

module Append where

data L a = N |  C a (L a) deriving (Eq)

data Proof = Proof 

{-@ measure append :: L a -> L a -> L a @-}
{-@ assume append :: xs:L a -> ys:L a -> {v:L a | v == append xs ys } @-}
append :: L a -> L a -> L a 
append N xs        = xs
append (C y ys) xs = C y (append ys xs) 

{-@ assume axiom_append_nil :: xs:L a -> {v:Proof | append N xs == xs} @-} 
axiom_append_nil :: L a -> Proof 
axiom_append_nil xs = Proof

{-@ assume axiom_append_cons :: x:a -> xs: L a -> ys: L a 
          -> {v:Proof | append (C x xs) ys == C x (append xs ys) } @-} 
axiom_append_cons :: a -> L a -> L a -> Proof 
axiom_append_cons x xs ys = Proof






{-@ prop_nil :: xs:L a -> {v:Proof | (append xs N == xs) <=> true } @-}
prop_nil     :: Eq a => L a -> Proof
prop_nil N   =  axiom_append_nil N 

prop_nil (C x xs) = toProof e1 $ eqProof e1 (eqProof e2 e3 pr2) pr1
   where
   	e1  = append (C x xs) N
   	pr1 = axiom_append_cons x xs N
   	e2  = C x (append xs N)
   	pr2 = prop_nil xs
   	e3  = C x xs


{-@ prop_assoc :: xs:L a -> ys:L a -> zs:L a
               -> {v:Proof | (append (append xs ys) zs == append xs (append ys zs))} @-}
prop_assoc :: Eq a => L a -> L a -> L a -> Proof
prop_assoc N ys zs = toProof (append (append N ys) zs) $
	                 eqProof (append (append N ys) zs) 
                    (eqProof (append ys zs) 
                             (append N (append ys zs))
                             (axiom_append_nil (append ys zs))
                    )(axiom_append_nil ys)     

prop_assoc (C x xs) ys zs = 
	toProof e1 $ 
	eqProof e1 (eqProof e2 (eqProof e3 (eqProof e4 e5 pr4) pr3) pr2) pr1 
  where
  	e1  = append (append (C x xs) ys) zs
  	pr1 = axiom_append_cons x xs ys
  	e2  = append (C x (append xs ys)) zs
  	pr2 = axiom_append_cons x (append xs ys) zs
  	e3  = C x (append (append xs ys) zs)
  	pr3 = prop_assoc xs ys zs
  	e4  = C x (append xs (append ys zs))
  	pr4 = axiom_append_cons x xs (append ys zs)
  	e5  = append (C x xs) (append ys zs)

                     
{-@ toProof :: l:a -> r:{a|l = r} -> {v:Proof | l = r } @-}
toProof :: a -> a -> Proof
toProof x y = Proof

{-@ eqProof :: l:a -> r:a -> {v:Proof | l = r} -> {v:a | v = l } @-}
eqProof :: a -> a -> Proof -> a 
eqProof x y _ = y 