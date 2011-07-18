
Require Import DDC.Data.List.Base.
Require Import DDC.Base.Tactics.


(********************************************************************)
(* Lemmas: Forall2 *)

Lemma Forall2_impl
 : forall (A B: Type) 
          (R1: A -> B -> Prop)
          (R2: A -> B -> Prop)
          xs ys
 , (forall x y, R1 x y -> R2 x y)
 -> Forall2 R1 xs ys 
 -> Forall2 R2 xs ys.
Proof.
 intros. induction H0; auto. 
Qed.


Lemma Forall2_impl_in
 : forall {A B: Type}
          (R1: A -> B -> Prop)
          (R2: A -> B -> Prop)
          (xs: list A)
          (ys: list B)
 ,  (forall x y, In x xs -> In y ys -> R1 x y -> R2 x y)
 -> Forall2 R1 xs ys
 -> Forall2 R2 xs ys.
Proof.
 intros.
 induction H0.
  apply Forall2_nil.
  intuition.
Qed.


Lemma Forall2_eq
 :  forall (A: Type) xs ys
 ,  Forall2 (@eq A) xs ys
 -> xs = ys.
Proof.
 intros.
 induction H.
 auto. 
 rewrite IHForall2.
 rewrite H. auto.
Qed.


Lemma Forall2_length
 : forall {A B: Type} (R: A -> B -> Prop) 
          (xs : list A) 
          (ys : list B)
 ,  Forall2 R xs ys
 -> length xs = length ys.
Proof.
 intros.
 induction H.
  auto.
  simpl. auto.
Qed.


Lemma Forall2_get_get_left
 :  forall (A B: Type) (R: A -> B -> Prop) x xs ys ix
 ,  Forall2 R xs ys
 -> get ix xs = Some x
 -> (exists y, get ix ys = Some y).
Proof.
 intros. gen ix x.
 induction H; intros. 
  false.
  destruct ix.
   simpl in H1. simpl. eauto.
   simpl in H1. simpl. eauto.
Qed.


Lemma Forall2_get_get_right
 :  forall (A B: Type) (R: A -> B -> Prop) y xs ys ix
 ,  Forall2 R xs ys
 -> get ix ys = Some y
 -> (exists x, get ix xs = Some x).
Proof.
 intros. gen ix y.
 induction H; intros. 
  false.
  destruct ix.
   simpl in H1. simpl. eauto.
   simpl in H1. simpl. eauto.
Qed.


Lemma Forall2_exists_in_left
 :  forall (A B: Type) (R: A -> B -> Prop) x xs ys
 ,  In x xs
 -> Forall2 R xs ys
 -> (exists y, In y ys).
Proof.
 intros.
 induction H0.
  false.
  exists y. simpl. auto.
Qed.


Lemma Forall2_exists_in_right
 :  forall (A B: Type) (R: A -> B -> Prop) y xs ys
 ,  In y ys
 -> Forall2 R xs ys
 -> (exists x, In x xs).
Proof.
 intros.
 induction H0.
  false.
  exists x. simpl. auto.
Qed.


Lemma Forall2_exists_left
 : forall (A B: Type) (R: A -> B -> Prop) x xs ys
 ,  In x xs 
 -> Forall2 R xs ys 
 -> (exists y, R x y).
Proof.
 intros.
 induction H0.
  false.
  simpl in H. destruct H.
   subst. eauto.
   eapply IHForall2. eauto.
Qed.
Hint Resolve Forall2_exists_left.


Lemma Forall2_exists_left_in
 : forall (A B: Type) (R: A -> B -> Prop) x xs ys
 ,             In x xs  -> Forall2 R xs ys 
 -> (exists y, In y ys  /\         R x  y).
Proof.
 intros.
 induction H0.
  false.
  simpl in H. destruct H.
   subst.
   exists y. split. simpl. auto. auto.
   lets D: IHForall2 H.
   destruct D.
   exists x1.
    inverts H2.
    split. simpl. auto. auto.
Qed.


Lemma Forall2_exists_right
 : forall (A B: Type) (R: A -> B -> Prop) y xs ys
 ,  In y ys 
 -> Forall2 R xs ys 
 -> (exists x, R x y).
Proof.
 intros.
 induction H0.
  false.
  simpl in H. destruct H.
   subst. eauto.
   eapply IHForall2. eauto.
Qed.
Hint Resolve Forall2_exists_right.


Lemma Forall2_map_left
 : forall {A B C: Type}
          (R1: B -> C -> Prop)
          (f:  A -> B)
          (xs: list A) (ys: list C)
 ,  Forall2 (fun x y => R1 (f x) y) xs ys
 -> Forall2 R1 (map f xs) ys.
Proof.
 intros.
 induction H.
  apply Forall2_nil.
  simpl. intuition.
Qed.


Lemma Forall2_map_right
 : forall {A B C: Type}
          (R1: A -> C -> Prop)
          (f:  B -> C)
          (xs: list A) (ys: list B)
 ,  Forall2 (fun x y => R1 x (f y)) xs ys
 -> Forall2 R1 xs (map f ys).
Proof.
 intros.
 induction H.
  apply Forall2_nil.
  simpl. intuition.
Qed.


Lemma Forall2_Forall_left
 : forall {A B : Type}
          (R   : A -> B -> Prop)
          (P   : A -> Prop)
          (xs  : list A)
          (ys  : list B)
 ,  Forall  (fun x => forall y, R x y -> P x) xs
 -> Forall2 R xs ys
 -> Forall  P xs.
Proof.
 intros.
 rewrite Forall_forall.
 rewrite Forall_forall in H. 
 intros.
 lets D: Forall2_exists_left H1 H0.
 destruct D. eauto. 
Qed.
Hint Resolve Forall2_Forall_left.


Lemma Forall2_swap
 :   forall {A B: Type} (R: A -> B -> Prop)
            (x x' : A)  (xs1 xs2: list A)
            (y: B)      (ys: list B)
 ,   (forall y, R x y -> R x' y)
 ->  Forall2 R (xs1 ++ x  :: xs2) ys
 ->  Forall2 R (xs1 ++ x' :: xs2) ys.
Proof.
 intros.
 lets D: Forall2_app_inv_l H0.
  destruct D  as [ys1].
  destruct H1 as [ys2].
  inverts H1. inverts H3.
  apply Forall2_app.
   auto.
  destruct ys2 as [ys2 | y'].
   inverts H1.
   inverts H1. eauto.
Qed.


Lemma Forall2_snoc
 : forall {A B : Type}
          (R   : A -> B -> Prop)
          (xs  : list A)
          (ys  : list B)
          x y
 ,  R x y
 -> Forall2 R xs ys
 -> Forall2 R (x <: xs) (y <: ys).
Proof.
 intros.
 induction H0.
  simpl. auto.
  simpl. auto.
Qed.
Hint Resolve Forall2_snoc.


Lemma Forall2_get_get_same
 : forall {A B : Type} 
          (R   : A -> B -> Prop)
          (xs  : list A)
          (ys  : list B)
          ix x y
 ,  Forall2 R xs ys
 -> get ix xs = Some x
 -> get ix ys = Some y
 -> R x y.
Proof.
 intros. gen ix.
 induction H; intros.
  false.
  destruct ix.
   simpl in H1. inverts H1.
   simpl in H2. inverts H2. 
   auto.

   simpl in H1.
   simpl in H2.
   eauto.
Qed.


