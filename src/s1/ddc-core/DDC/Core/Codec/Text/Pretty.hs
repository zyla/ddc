{-# LANGUAGE TypeFamilies #-}

-- | Pretty printing for core modules and expressions.
module DDC.Core.Codec.Text.Pretty
        ( module DDC.Core.Codec.Text.Pretty.Type
        , module DDC.Data.Pretty
        , PrettyMode (..)
        , pprExportType, pprExportValue
        , pprImportType, pprImportValue
        , pprDataDef,    pprDataCtor
        , pprTypeDef)
where
import DDC.Core.Codec.Text.Pretty.Type
import DDC.Core.Exp.Annot.Exp
import DDC.Core.Exp.Annot.Pretty
import DDC.Core.Exp.Annot.Compounds
import DDC.Type.DataDef
import DDC.Core.Module
import DDC.Data.Pretty
import Data.List
import Prelude                  hiding ((<$>))


-- ModuleName -------------------------------------------------------------------------------------
instance Pretty ModuleName where
 ppr (ModuleName parts)
        = text $ intercalate "." parts


-- Module -----------------------------------------------------------------------------------------
instance (Pretty n, Eq n) => Pretty (Module a n) where
 data PrettyMode (Module a n)
        = PrettyModeModule
        { modeModuleLets                :: PrettyMode (Lets a n)
        , modeModuleSuppressImports     :: Bool
        , modeModuleSuppressExports     :: Bool }

 pprDefaultMode
        = PrettyModeModule
        { modeModuleLets                = pprDefaultMode
        , modeModuleSuppressImports     = False
        , modeModuleSuppressExports     = False }

 pprModePrec mode _
        ModuleCore
        { moduleName            = name
        , moduleExportTypes     = exportTypes
        , moduleExportValues    = exportValues
        , moduleImportTypes     = importTypes
        , moduleImportCaps      = importCaps
        , moduleImportValues    = importValues
        , moduleImportDataDefs  = importData
        , moduleImportTypeDefs  = importType
        , moduleLocalDataDefs   = localData
        , moduleLocalTypeDefs   = localType
        , moduleBody            = body }
  = {-# SCC "ppr[Module]" #-}
    let
        (lts, _)                = splitXLets body

        -- Exports --------------------
        dExportTypes
         | null $ exportTypes   = empty
         | otherwise            = (vcat $ map (pprExportType  . snd) exportTypes)  <> line

        dExportValues
         | null $ exportValues  = empty
         | otherwise            = (vcat $ map (pprExportValue . snd) exportValues) <> line

        -- Imports --------------------
        dImportTypes
         | null $ importTypes   = empty
         | otherwise            = (vcat $ map pprImportType  importTypes)  <> line

        dImportCaps
         | null $ importCaps    = empty
         | otherwise            = (vcat $ map pprImportCap   importCaps)   <> line

        dImportValues
         | null $ importValues  = empty
         | otherwise            = (vcat $ map (pprImportValue . snd) importValues) <> line

        docsImportsExports
         -- If we're suppressing imports, then don't print it.
         | modeModuleSuppressImports mode
         = empty

         -- If there are no imports or exports then suppress printing.
         | null exportTypes, null exportValues
         , null importTypes, null importCaps, null importValues
         = empty

         | otherwise
         = line <> dExportTypes <> dExportValues
                <> dImportTypes <> dImportCaps <> dImportValues

        -- Data Definitions -----
        docsDataImport
         | null importData = empty
         | otherwise
         = line <> vsep  (map (\i -> text "import" <+> ppr i) $ map snd importData)

        docsDataLocal
         | null localData = empty
         | otherwise
         = line <> vsep  (map ppr $ map snd localData)

        -- Type Definitions -----
        docsTypeImport
         | null importType = empty
         | otherwise
         = line <> vsep  (map (\i -> text "import" <+> pprTypeDef i) $ importType)

        docsTypeLocal
         | null localType  = empty
         | otherwise
         = line <> vsep  (map pprTypeDef localType)

        pprLts = pprModePrec (modeModuleLets mode) 0

    in  text "module" <+> ppr name
         <+> docsImportsExports
         <>  docsDataImport
         <>  docsDataLocal
         <>  docsTypeImport
         <>  docsTypeLocal
         <>  (case lts of
                []       -> empty
                [LRec[]] -> empty
                _        -> text "with" <$$> (vcat $ map pprLts lts))


-- Exports ----------------------------------------------------------------------------------------
-- | Pretty print an exported type definition.
pprExportType :: (Pretty n, Pretty t) => ExportType n t -> Doc
pprExportType esrc
 = case esrc of
        ExportTypeLocalNoKind n
         -> text "export type" <+> ppr n <> semi

        ExportTypeLocal n k
         -> text "export type" <+> padL 10 (ppr n) <> text ":" <+> ppr k <> semi


-- | Pretty print an exported value definition.
pprExportValue :: (Pretty n, Pretty t) => ExportValue n t -> Doc
pprExportValue esrc
 = case esrc of
        ExportValueLocalNoType n
         -> text "export value" <+> ppr n <> semi

        ExportValueLocal mn n t Nothing
         -> text "export value"
                <+> padL 10 (ppr mn <> text "." <> ppr n)
                <>  text ":"
                <+> ppr t <> semi

        ExportValueLocal mn n t (Just (arityType, arityValue, arityBoxes))
         -> vcat [ text "export value"
                        <+> padL 10 (ppr mn <> text "." <> ppr n)
                        <>  text ":"
                        <+> ppr t <> semi

                 , text "{-# ARITY   "
                        <+> padL 10 (ppr mn <> text "." <> ppr n)
                        <+> ppr arityType
                        <+> ppr arityValue
                        <+> ppr arityBoxes
                        <+> text "#-}"
                 , empty ]

        ExportValueSea iName xName t
         -> vcat [ text "export foreign c value"
                 , indent 8 (padL 15 (ppr iName) <> text ":" <+> ppr t <> semi)
                 , indent 8 (text " from " <> text (show xName)) ]


-- Imports ----------------------------------------------------------------------------------------
-- | Pretty print a type import.
pprImportType :: (Pretty n, Pretty t) => (n, ImportType n t) -> Doc
pprImportType (n, isrc)
 = case isrc of
        ImportTypeAbstract k
         -> text "import foreign abstract type" <> line
         <> indent 8 (ppr n <+> text ":" <+> ppr k <> semi)
         <> line

        ImportTypeBoxed k
         -> text "import foreign boxed type" <> line
         <> indent 8 (ppr n <+> text ":" <+> ppr k <> semi)
         <> line


-- | Pretty print a capability import.
pprImportCap :: (Pretty n, Pretty t) => (n, ImportCap n t) -> Doc
pprImportCap (n, isrc)
 = case isrc of
        ImportCapAbstract t
         -> text "import foreign abstract capability" <> line
         <> indent 8 (padL 15 (ppr n) <+> text ":" <+> ppr t <> semi)
         <> line


-- | Pretty print a value import.
pprImportValue :: (Pretty n, Pretty t) => ImportValue n t -> Doc
pprImportValue isrc
 = case isrc of
        ImportValueModule mn n t Nothing
         ->        text "import value"
                        <+> padL 10 (ppr mn <> text "." <> ppr n)
                        <+> text ":" <+> ppr t
                        <>  semi

        ImportValueModule mn n t (Just (arityType, arityValue, arityBoxes))
         -> vcat [ text "import value"
                        <+> padL 10 (ppr mn <> text "." <> ppr n)
                        <+> text ":" <+> ppr t
                        <>  semi

                 , text "{-# ARITY   "
                        <+> padL 10 (ppr mn <> text "." <> ppr n)
                        <+> ppr arityType <+> ppr arityValue <+> ppr arityBoxes
                        <+> text "#-}"

                 , empty ]

        ImportValueSea nInternal _nExternal t
         -> text "import foreign c value" <> line
         <> indent 8 (padL 15 (ppr nInternal) <+> text ":" <+> ppr t <> semi)
         <> line


-- DataDef ----------------------------------------------------------------------------------------
instance (Pretty n, Eq n) => Pretty (DataDef n) where
 pprPrec _ def = pprDataDef def


-- | Pretty print a data type definition.
pprDataDef :: (Pretty n, Eq n) => DataDef n -> Doc
pprDataDef def
  =   (text "data"
        <+> hsep ( ppr (dataDefTypeName def)
                 : map (parens . ppr) (dataDefParams def))
        <+> text "where"
        <+>  lbrace)
  <$> (case dataDefCtors def of
        Just ctors
         -> indent 8
          $ vcat [ ppr ctor <> semi | ctor <- ctors]

        Nothing
         -> text "LARGE")
  <> line <> rbrace <> line


-- DataCtor ---------------------------------------------------------------------------------------
instance (Pretty n, Eq n) => Pretty (DataCtor n) where
 pprPrec _ def = pprDataCtor def


-- | Pretty print a data constructor definition.
pprDataCtor :: (Pretty n, Eq n) => DataCtor n -> Doc
pprDataCtor ctor
        =   ppr (dataCtorName ctor)
        <+> text ":"
        <+> (hsep $ punctuate (text " ->")
                  $ (map (pprPrec 6)
                        (   dataCtorFieldTypes ctor
                        ++ [dataCtorResultType ctor])))


-- TypeDef -----------------------------------------------------------------------------------------
-- | Pretty print a type definition.
pprTypeDef :: (Pretty n, Eq n) => (n, (Kind n, Type n)) -> Doc
pprTypeDef (n, (k, t))
 =  text "type" <+> ppr n
                <+> text ":" <+> ppr k
                <+> text "=" <+> ppr t
 <> semi <> line

