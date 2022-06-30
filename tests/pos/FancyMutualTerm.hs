{-@ measure self :: a  @-}


{-# LANGUAGE GADTs #-}
{-@ measure tsize :: Tree a -> Nat @-}
{-@ invariant {t:Tree a | 0 <= tsize t} @-}

data Tree a where 
    Leaf :: a -> Tree a 
    Node :: (Int -> (Tree a)) -> Tree a 

{-@ data Tree a where 
      Leaf :: a -> {t:Tree a  | tsize t == 0 } 
      Node :: f:(Int -> ({tt:Tree a | tsize tt < tsize self })) 
           -> Tree a  @-}


{-@ mapTr :: (a -> a) -> t:Tree a -> Tree a / [tsize t, 2] @-}
mapTr :: (a -> a) -> Tree a -> Tree a 
mapTr f (Leaf x) = Leaf (f x) 
mapTr f d@(Node n) = Node (mapTr2 d f n)


{-@ mapTr2 :: t:Tree a -> (a -> a) -> (Int -> {tt:Tree a | tsize tt < tsize t }) -> Int -> Tree a / [tsize t, 1] @-} 
mapTr2 :: Tree a -> (a -> a) -> (Int -> Tree a) -> Int -> Tree a  
mapTr2 _ f n x = mapTr f (n x)


