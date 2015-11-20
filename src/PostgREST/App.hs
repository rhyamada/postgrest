{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
--module PostgREST.App where
module PostgREST.App (
  app
, contentTypeForAccept
) where

import           Control.Applicative
import           Control.Arrow             ((***))
import           Control.Monad             (join)
import           Data.Bifunctor            (first)
import qualified Data.ByteString.Char8     as BS
import qualified Data.ByteString.Lazy      as BL
--import qualified Data.Csv                  as CSV
import           Data.Functor.Identity
import qualified Data.HashMap.Strict       as HM
import           Data.List                 (find, sortBy, delete, transpose)
import           Data.Maybe                (fromMaybe, fromJust, isJust, isNothing, mapMaybe)
import           Data.Ord                  (comparing)
import           Data.Ranged.Ranges        (emptyRange, singletonRange)
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text, replace, strip)
import           Data.Tree
import qualified Data.Map                  as M
import qualified Data.Aeson                as JSON

import           Text.Parsec.Error
import           Text.ParserCombinators.Parsec (parse)

import           Network.HTTP.Base         (urlEncodeVars)
import           Network.HTTP.Types.Header
import           Network.HTTP.Types.Status
import           Network.HTTP.Types.URI    (parseSimpleQuery)
import           Network.Wai
import           Network.Wai.Parse         (parseHttpAccept)

import           Data.Aeson
import           Data.Aeson.Types (emptyArray)
import           Data.Monoid
import qualified Data.Vector               as V
import qualified Hasql                     as H
import qualified Hasql.Backend             as B
import qualified Hasql.Postgres            as P

import           PostgREST.Config          (AppConfig (..))
import           PostgREST.Parsers
import           PostgREST.DbStructure
import           PostgREST.RangeQuery
import           PostgREST.RequestIntent   (Intent(..), ContentType(..)
                                            , Action(..), Target(..)
                                            , Payload(..), userIntent)
import           PostgREST.Types
import           PostgREST.Auth            (tokenJWT)
import           PostgREST.Error           (errResponse)

import           PostgREST.QueryBuilder ( asJson
                                        , callProc
                                        , asCsvF
                                        , asJsonF
                                        , selectStarF
                                        , countF
                                        , locationF
                                        , asJsonSingleF
                                        , addJoinConditions
                                        , sourceSubqueryName
                                        , requestToQuery
                                        , wrapQuery
                                        , countAllF
                                        , countNoneF
                                        , addRelations
                                        )

import           Prelude

app :: DbStructure -> AppConfig -> RequestBody -> Request -> H.Tx P.Postgres s Response
app dbStructure conf reqBody req =
  let
      -- TODO: blow up for Left values
      contentType = either (const ApplicationJSON) id (iAccepts intent)
      contentTypeS ct = case ct of
        ApplicationJSON -> "application/json"
        TextCSV -> "text/csv"
      contentTypeH = (hContentType, contentTypeS contentType) in

  case (iAction intent, iTarget intent, iPayload intent) of
    (ActionUnknown _, _, _) -> return notFound
    (_, TargetUnknown _, _) -> return notFound
    (_, _, Just (PayloadParseError e)) ->
      return $ responseLBS status400 [jsonH] $
        cs (formatGeneralError "Cannot parse request payload" (cs e))

    (ActionInfo, TargetIdent (QualifiedIdentifier tSchema tTable), _) -> do
      let cols = filter (filterCol tSchema tTable) $ dbColumns dbStructure
          pkeys = map pkName $ filter (filterPk tSchema tTable) allPrKeys
          body = encode (TableOptions cols pkeys)
          filterCol :: Schema -> TableName -> Column -> Bool
          filterCol sc tb (Column{colTable=Table{tableSchema=s, tableName=t}}) = s==sc && t==tb
          filterCol _ _ _ =  False
      return $ responseLBS status200 [jsonH, allOrigins] $ cs body

    (ActionRead, TargetRoot, _) -> do
      body <- encode <$> accessibleTables (filter ((== cs schema) . tableSchema) (dbTables dbStructure))
      return $ responseLBS status200 [jsonH] $ cs body

    (ActionInvoke, TargetIdent qi, Just (PayloadJSON payload)) -> do
      exists <- doesProcExist qi
      if exists
        then do
          let p = case pp of
                    JSON.Object o -> o
                    _ -> undefined
                  where pp = V.head payload
              call = B.Stmt "select " V.empty True <>
                asJson (callProc qi p)
              jwtSecret = configJwtSecret conf

          bodyJson :: Maybe (Identity Value) <- H.maybeEx call
          returnJWT <- doesProcReturnJWT qi
          return $ responseLBS status200 [jsonH]
                 (let body = fromMaybe emptyArray $ runIdentity <$> bodyJson in
                    if returnJWT
                    then "{\"token\":\"" <> cs (tokenJWT jwtSecret body) <> "\"}"
                    else cs $ encode body)
        else return notFound

    (ActionRead, TargetIdent qi, _) ->
      case selectQuery of
        Left e -> return $ responseLBS status400 [jsonH] $ cs e
        Right q -> do
          let range = iRange intent
              singular = iPreferSingular intent
              stm = createReadStatement q range singular
                    (iPreferCount intent) (contentType == TextCSV)
          if range == Just emptyRange
          then return $ errResponse status416 "HTTP Range error"
          else do
            row <- H.maybeEx stm
            let (tableTotal, queryTotal, _ , body) = extractQueryResult row
            if singular
            then return $ if queryTotal <= 0
              then responseLBS status404 [] ""
              else responseLBS status200 [contentTypeH] (fromMaybe "{}" body)
            else do
              let frm = fromMaybe 0 $ rangeOffset <$> range
                  to = frm+queryTotal-1
                  contentRange = contentRangeH frm to tableTotal
                  status = rangeStatus frm to tableTotal
                  canonical = urlEncodeVars -- should this be moved to the dbStructure (location)?
                    . sortBy (comparing fst)
                    . map (join (***) cs)
                    . parseSimpleQuery
                    $ rawQueryString req
              return $ responseLBS status
                [contentTypeH, contentRange,
                  ("Content-Location",
                    "/" <> cs (qiName qi) <>
                      if Prelude.null canonical then "" else "?" <> cs canonical
                  )
                ] (fromMaybe "[]" body)
    (ActionCreate, TargetIdent (QualifiedIdentifier _ table), _) ->
      case queries of
        Left e -> return $ responseLBS status400 [jsonH] $ cs e
        Right (sq,mq,isSingle) -> do
          let pKeys = map pkName $ filter (filterPk schema table) allPrKeys -- would it be ok to move primary key detection in the query itself?
          let stm = createWriteStatement sq mq isSingle (iPreferRepresentation intent) pKeys (contentType == TextCSV)
          row <- H.maybeEx stm
          let (_, _, location, body) = extractQueryResult row
          return $ responseLBS status201
            [
              contentTypeH,
              (hLocation, "/" <> cs table <> "?" <> cs (fromMaybe "" location))
            ]
            $ if iPreferRepresentation intent then fromMaybe "[]" body else ""
    (ActionUpdate, TargetIdent _, _) ->
      case queries of
        Left e -> return $ responseLBS status400 [jsonH] $ cs e
        Right (sq,mq,_) -> do
          let stm = createWriteStatement sq mq False (iPreferRepresentation intent) [] (contentType == TextCSV)
          row <- H.maybeEx stm
          let (_, queryTotal, _, body) = extractQueryResult row
              r = contentRangeH 0 (queryTotal-1) (Just queryTotal)
              s = case () of _ | queryTotal == 0 -> status404
                               | iPreferRepresentation intent -> status200
                               | otherwise -> status204
          return $ responseLBS s [contentTypeH, r]
            $ if iPreferRepresentation intent then fromMaybe "[]" body else ""
    (ActionDelete, TargetIdent _, _) ->
      case queries of
        Left e -> return $ responseLBS status400 [jsonH] $ cs e
        Right (sq,mq,_) -> do
          let stm = createWriteStatement sq mq False False [] (contentType == TextCSV)
          row <- H.maybeEx stm
          let (_, queryTotal, _, _) = extractQueryResult row
          return $ if queryTotal == 0
            then notFound
            else responseLBS status204 [("Content-Range", "*/"<> cs (show queryTotal))] ""

    (_, _, _) -> return notFound

 where
  notFound = responseLBS status404 [] ""
  filterPk sc table pk = sc == (tableSchema . pkTable) pk && table == (tableName . pkTable) pk
  allPrKeys = dbPrimaryKeys dbStructure
  allOrigins = ("Access-Control-Allow-Origin", "*") :: Header
  schema = cs $ configSchema conf
  intent = userIntent schema req reqBody
  selectApiRequest = buildSelectApiRequest intent (dbRelations dbStructure)
  selectQuery = requestToQuery schema <$> selectApiRequest
  mutateTuple = buildMutateApiRequest intent
  mutateApiRequest = fst <$> mutateTuple
  isSingleRecord = snd <$> mutateTuple
  mutateQuery = requestToQuery schema <$> mutateApiRequest
  queries = (,,) <$> selectQuery <*> mutateQuery <*> isSingleRecord

rangeStatus :: Int -> Int -> Maybe Int -> Status
rangeStatus _ _ Nothing = status200
rangeStatus frm to (Just total)
  | frm > total            = status416
  | (1 + to - frm) < total = status206
  | otherwise               = status200

contentRangeH :: Int -> Int -> Maybe Int -> Header
contentRangeH frm to total =
    ("Content-Range", cs headerValue)
    where
      headerValue   = rangeString <> "/" <> totalString
      rangeString
        | totalNotZero && fromInRange = show frm <> "-" <> cs (show to)
        | otherwise = "*"
      totalString   = fromMaybe "*" (show <$> total)
      totalNotZero  = fromMaybe True ((/=) 0 <$> total)
      fromInRange   = frm <= to

jsonMT :: BS.ByteString
jsonMT = "application/json"

csvMT :: BS.ByteString
csvMT = "text/csv"

allMT :: BS.ByteString
allMT = "*/*"

jsonH :: Header
jsonH = (hContentType, jsonMT)

contentTypeForAccept :: Maybe BS.ByteString -> Maybe BS.ByteString
contentTypeForAccept accept
  | isNothing accept || has allMT || has jsonMT = Just jsonMT
  | has csvMT = Just csvMT
  | otherwise = Nothing
  where
    Just acceptH = accept
    findInAccept = flip find $ parseHttpAccept acceptH
    has          = isJust . findInAccept . BS.isPrefixOf

formatRelationError :: Text -> Text
formatRelationError = formatGeneralError
  "could not find foreign keys between these entities"

formatParserError :: ParseError -> Text
formatParserError e = formatGeneralError message details
  where
     message = cs $ show (errorPos e)
     details = strip $ replace "\n" " " $ cs
       $ showErrorMessages "or" "unknown parse error" "expecting" "unexpected" "end of input" (errorMessages e)

formatGeneralError :: Text -> Text -> Text
formatGeneralError message details = cs $ encode $ object [
  "message" .= message,
  "details" .= details]

-- parseRequestBody :: Bool -> RequestBody -> Either Text ([Text],[[Value]])
-- parseRequestBody isCsv reqBody = first cs $
--   checkStructure =<<
--   if isCsv
--   then do
--     rows <- (map V.toList . V.toList) <$> CSV.decode CSV.NoHeader reqBody
--     if null rows then Left "CSV requires header" -- TODO! should check if length rows > 1 (header and 1 row)
--       else Right (head rows, (map $ map $ parseCsvCell . cs) (tail rows))
--   else eitherDecode reqBody >>= convertJson
--   where
--     checkStructure :: ([Text], [[Value]]) -> Either String ([Text], [[Value]])
--     checkStructure v
--       | headerMatchesContent v = Right v
--       | isCsv = Left "CSV header does not match rows length"
--       | otherwise = Left "The number of keys in objects do not match"
--
--     headerMatchesContent :: ([Text], [[Value]]) -> Bool
--     headerMatchesContent (header, vals) = all ( (headerLength ==) . length) vals
--       where headerLength = length header

convertJson :: Value -> Either Text ([Text],[[Value]])
convertJson v = (,) <$> (header <$> normalized) <*> (vals <$> normalized)
  where
    invalidMsg = "Expecting single JSON object or JSON array of objects"::Text
    normalized :: Either Text [(Text, [Value])]
    normalized = groupByKey =<< normalizeValue v

    vals :: [(Text, [Value])] -> [[Value]]
    vals = transpose . map snd

    header :: [(Text, [Value])] -> [Text]
    header = map fst

    groupByKey :: Value -> Either Text [(Text,[Value])]
    groupByKey (Array a) = HM.toList . foldr (HM.unionWith (++)) (HM.fromList []) <$> maps
      where
        maps :: Either Text [HM.HashMap Text [Value]]
        maps = mapM getElems $ V.toList a
        getElems (Object o) = Right $ HM.map (:[]) o
        getElems _ = Left invalidMsg
    groupByKey _ = Left invalidMsg

    normalizeValue :: Value -> Either Text Value
    normalizeValue val =
      case val of
        Object obj  -> Right $ Array (V.fromList[Object obj])
        a@(Array _) -> Right a
        _ -> Left invalidMsg

augumentRequestWithJoin :: Schema ->  [Relation] ->  ApiRequest -> Either Text ApiRequest
augumentRequestWithJoin schema allRels request =
  (first formatRelationError . addRelations schema allRels Nothing) request
  >>= addJoinConditions schema

buildSelectApiRequest :: Intent -> [Relation] -> Either Text ApiRequest
buildSelectApiRequest intent allRels =
  augumentRequestWithJoin schema rels =<< first formatParserError (foldr addFilter <$> (addOrder <$> apiRequest <*> ord) <*> flts)
  where
    selStr = iSelect intent
    orderS = iOrder intent
    action = iAction intent
    target = iTarget intent
    (schema, rootTableName) = fromJust $ -- Make it safe
      case target of
        (TargetIdent (QualifiedIdentifier s t) ) -> Just (s, t)
        _ -> Nothing

    rootName = if action == ActionRead
      then rootTableName
      else sourceSubqueryName
    filters = if action == ActionRead
      then iFilters intent
      else filter (( '.' `elem` ) . fst) $ iFilters intent -- there can be no filters on the root table whre we are doing insert/update
    rels = case action of
      ActionCreate -> fakeSourceRelations ++ allRels
      ActionUpdate -> fakeSourceRelations ++ allRels
      _       -> allRels
      where fakeSourceRelations = mapMaybe (toSourceRelation rootTableName) allRels -- see comment in toSourceRelation
    apiRequest = parse (pRequestSelect rootName) ("failed to parse select parameter <<"++selStr++">>") selStr
    addOrder (Node (q,i) f) o = Node (q{order=o}, i) f
    flts = mapM pRequestFilter filters
    ord = traverse (parse pOrder ("failed to parse order parameter <<"++fromMaybe "" orderS++">>")) orderS

buildMutateApiRequest :: Intent -> Either Text (ApiRequest, Bool)
buildMutateApiRequest intent =
  (,) <$> mutateApiRequest <*> pure isSingleRecord
  where
    action = iAction intent
    target = iTarget intent
    rootTableName = fromJust $ -- Make it safe
      case target of
        (TargetIdent (QualifiedIdentifier _ t) ) -> Just t
        _ -> Nothing
    mutateApiRequest = case action of
      ActionCreate -> Node <$> ((,) <$> (Insert rootTableName <$> flds <*> vals)    <*> pure (rootTableName, Nothing)) <*> pure []
      ActionUpdate -> Node <$> ((,) <$> (Update rootTableName <$> setWith <*> cond) <*> pure (rootTableName, Nothing)) <*> pure []
      ActionDelete -> Node <$> ((,) <$> (Delete [rootTableName] <$> cond) <*> pure (rootTableName, Nothing)) <*> pure []
      _        -> Left "Unsupported HTTP verb"
    parseField f = parse pField ("failed to parse field <<"++f++">>") f
    payload = case iPayload intent of
      Just (PayloadJSON v) -> JSON.Array v
      _ -> undefined --TODO! fix
    parsedBody = convertJson payload -- TODO! either check structure or refactor to send json directly to postgres
    isSingleRecord = either (const False) ((==1) . length . snd ) parsedBody
    flds =  join $ first formatParserError . mapM (parseField . cs) <$> (fst <$> parsedBody)
    vals = snd <$> parsedBody
    mutateFilters = filter (not . ( '.' `elem` ) . fst) $ iFilters intent -- update/delete filters can be only on the root table
    cond = first formatParserError $ map snd <$> mapM pRequestFilter mutateFilters
    setWith = if isSingleRecord
          then M.fromList <$> (zip <$> flds <*> (head <$> vals))
          else Left "Expecting a sigle CSV line with header or a JSON object"

addFilter :: (Path, Filter) -> ApiRequest -> ApiRequest
addFilter ([], flt) (Node (q@(Select {where_=flts}), i) forest) = Node (q {where_=flt:flts}, i) forest
addFilter (path, flt) (Node rn forest) =
  case targetNode of
    Nothing -> Node rn forest -- the filter is silenty dropped in the Request does not contain the required path
    Just tn -> Node rn (addFilter (remainingPath, flt) tn:restForest)
  where
    targetNodeName:remainingPath = path
    (targetNode,restForest) = splitForest targetNodeName forest
    splitForest name forst =
      case maybeNode of
        Nothing -> (Nothing,forest)
        Just node -> (Just node, delete node forest)
      where maybeNode = find ((name==).fst.snd.rootLabel) forst

-- in a relation where one of the tables mathces "TableName"
-- replace the name to that table with pg_source
-- this "fake" relations is needed so that in a mutate query
-- we can look a the "returning *" part which is wrapped with a "with"
-- as just another table that has relations with other tables
toSourceRelation :: TableName -> Relation -> Maybe Relation
toSourceRelation mt r@(Relation t _ ft _ _ rt _ _)
  | mt == tableName t = Just $ r {relTable=t {tableName=sourceSubqueryName}}
  | mt == tableName ft = Just $ r {relFTable=t {tableName=sourceSubqueryName}}
  | Just mt == (tableName <$> rt) = Just $ r {relLTable=(\tbl -> tbl {tableName=sourceSubqueryName}) <$> rt}
  | otherwise = Nothing

data TableOptions = TableOptions {
  tblOptcolumns :: [Column]
, tblOptpkey    :: [Text]
}

instance ToJSON TableOptions where
  toJSON t = object [
      "columns" .= tblOptcolumns t
    , "pkey"   .= tblOptpkey t ]

createReadStatement :: SqlQuery -> Maybe NonnegRange -> Bool -> Bool -> Bool -> B.Stmt P.Postgres
createReadStatement selectQuery range isSingle countTable asCsv =
  B.Stmt (
    wrapQuery selectQuery [
      if countTable then countAllF else countNoneF,
      countF,
      "null", -- location header can not be calucalted
      if asCsv
        then asCsvF
        else if isSingle then asJsonSingleF else asJsonF
    ] selectStarF (if isNothing range && isSingle then Just $ singletonRange 0 else range)
  ) V.empty True

createWriteStatement :: SqlQuery -> SqlQuery -> Bool -> Bool -> [Text] -> Bool -> B.Stmt P.Postgres
createWriteStatement selectQuery mutateQuery isSingle echoRequested pKeys asCsv =
  B.Stmt (
    wrapQuery mutateQuery [
      countNoneF, -- when updateing it does not make sense
      countF,
      if isSingle then locationF pKeys else "null",
      if echoRequested
      then
        if asCsv
        then asCsvF
        else if isSingle then asJsonSingleF else asJsonF
      else "null"

    ] selectQuery Nothing
  ) V.empty True

extractQueryResult :: Maybe (Maybe Int, Int, Maybe BL.ByteString, Maybe BL.ByteString)
                         -> (Maybe Int, Int, Maybe BL.ByteString, Maybe BL.ByteString)
extractQueryResult = fromMaybe (Just 0, 0, Just "", Just "")
