
module DDC.Core.Check.Exp.Inst
        (checkSub)
where
import DDC.Core.Check.Exp.Base

-- Sub ------------------------------------------------------------------------
-- This is the subtyping rule for the type checking judgment.
checkSub table !a ctx0 xx tExpect
 = do
        (xx', tSynth, eff, clo, ctx1)
         <- tableCheckExp table table ctx0 xx Synth

        -- Substitute context into synthesised and expected types.
        let tExpect'    = applyContext ctx0 tExpect
        let tSynth'     = applyContext ctx0 tSynth

        ctx2    <- makeSub table a ctx1 tSynth' tExpect'

        --trace (renderIndent $ vcat
        --        [ text "* Sub"
        --        , text "  " <> ppr xx
        --        , text "  tSynth   = " <> ppr tSynth
        --        , text "  tExpect  = " <> ppr tExpect
        --        , text "  tSynth'  = " <> ppr tSynth'
        --        , text "  tExpect' = " <> ppr tExpect'
        --        , indent 2 $ ppr ctx2 ]) $ return ()

        returnX a
                (\_ -> xx')
                tExpect
                eff clo ctx2


-- makeSub --------------------------------------------------------------------
-- Make one type a subtype of another.
makeSub table a ctx0 tL tR

 -- SubExvar
 | Just iL <- takeExists tL
 , Just iR <- takeExists tR
 , iL == iR
 = return ctx0

 -- SubInstantiateR
 --  TODO: do free variables check  tR /= FV(tL)
 | isTExists tR
 = inst table a ctx0 tL tR

 | otherwise
 = error $ renderIndent $ vcat
        [ text "subInstR: no match" 
        , text "tL = " <> ppr tL
        , text "tR = " <> ppr tR ]


-- Inst ----------------------------------------------------------------------
inst table !a ctx0 tL tR

 -- InstLReach
 | Just iL <- takeExists tL
 , Just iR <- takeExists tR
 , iL < iR                      -- iL bound earlier in the stack.
 = do   let ctx1        = updateExists [] iR tL ctx0
        return ctx1

 -- InstRReach
 | Just iL <- takeExists tL
 , Just iR <- takeExists tR
 , iR < iL                      -- iR bound earlier in the stack.
 = do   let !ctx1       = updateExists [] iL tR ctx0
        return ctx1

 -- InstRArr
 | Just (tL1, tL2)      <- takeTFun tL
 , Just iR              <- takeExists tR
 = do   
        -- Make new existentials to match the function type and parameter.
        iR1      <- newExists
        let tR1  =  typeOfExists iR1 

        iR2      <- newExists
        let tR2  =  typeOfExists iR2

        -- Update the context with the new constraint.
        let ctx1 =  updateExists [iR2, iR1] iR (tFun tR1 tR2) ctx0

        -- Instantiate the parameter type.
        ctx2     <- inst table a ctx1 tR1 tL1

        -- Substitute into tL2
        let tL2' = applyContext ctx2 tL2

        -- Instantiate the return type.
        ctx3     <- inst table a ctx2 tL2' tR2 

        --trace (renderIndent $ vcat
        --        [ text "* InstRArr"
        --        , text "  tL = " <> ppr tL
        --        , text "  iR = " <> ppr iR
        --        , indent 2 $ ppr ctx3 ]) $ return ()

        return ctx3

 | otherwise
 = error $ renderIndent $ vcat
        [ text "inst: blerk"
        , text "  tL: " <> ppr tL
        , text "  tR: " <> ppr tR ]


