module GraphQL.Type where

import Prelude

import Data.Argonaut.Core as Json
import Data.Argonaut.Encode (extend)
import Data.Either (Either(..))
import Data.List (List)
import Data.Map (Map, empty, insert, lookup)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Symbol (class IsSymbol, SProxy(..), reflectSymbol)
import Data.Traversable (find, foldr, traverse)
import Data.Tuple (Tuple(..))
import GraphQL.Language.AST as AST
import Record as Record
import Type.Data.RowList (RLProxy(..))
import Type.Row as Row
import Type.RowList as RL
import Unsafe.Coerce (unsafeCoerce)

-- | The schema contains the central entry points for GraphQL queries.
newtype Schema a = Schema { query :: ObjectType a }

-- | The input type class is used for all GraphQL types that can be used as input types.
class InputType t where
  parseLiteral :: forall a. t a -> AST.ValueNode -> Either String a
  parseValue :: forall a. t a -> Json.Json -> Either String a

-- | The output type class is used for all GraphQL types that can be used as output types.
class OutputType t where
  serialize :: forall a. t a -> Maybe AST.SelectionSetNode -> a -> Either String Json.Json

-- | Scalar types are the leaf nodes of a GraphQL schema. Scalar types can be serialised into JSON
-- | or obtained from a JSON when read from the variables provided by a query. Furthermore values
-- | can be read from literals in a GraphQL document. To create a scalar type a name and optionally
-- | a description need to be provided.
-- | The functions `parseLiteral`, `parseValue` and `serialize` are used to convert between the
-- | GraphQL transport formats and PureScript representations.
-- |
-- | The GraphQL PureScript implementation comes with the four default scalars defined in the
-- | specification.
newtype ScalarType a =
  ScalarType
    { name :: String
    , description :: Maybe String
    , parseLiteral :: AST.ValueNode -> Either String a
    , parseValue :: Json.Json -> Either String a
    , serialize :: a -> Json.Json
    }

instance inputTypeScalarType :: InputType ScalarType where
  parseLiteral (ScalarType s) = s.parseLiteral
  parseValue (ScalarType s) = s.parseValue

instance outputTypeScalarType :: OutputType ScalarType where
  serialize (ScalarType s) Nothing val = pure $ s.serialize val
  serialize _ _ _ = Left "Invalid subselection on scalar type!"

instance showScalarType :: Show (ScalarType a) where
  show (ScalarType { name }) = "scalar " <> name

newtype ObjectType a =
  ObjectType
    { name :: String
    , description :: Maybe String
    , fields :: Map String (ExecutableField a)
    }

instance outputTypeObjectType :: OutputType ObjectType where
  serialize (ObjectType o) (Just (AST.SelectionSetNode { selections })) val =
    foldr extend Json.jsonEmptyObject <$> traverse serializeField selections
      where
        serializeField node@(AST.FieldNode fld) =
          let (AST.NameNode { value: name }) = fld.name
              (AST.NameNode { value: alias }) = fromMaybe fld.name fld.alias
          in case lookup name o.fields of
            Just (ExecutableField { execute }) ->
              execute val node >>= (Tuple alias >>> pure)
            Nothing -> Left ("Unknown field `" <> name <> "` in selection.")
        serializeField _ = Left "Error!"
  serialize _ _ _ = Left "Missing subselection on object type."

instance showObjectType :: Show (ObjectType a) where
  show (ObjectType { name }) = "type " <> name

-- | The executable field loses the information about it's arguments types. This is needed to add it
-- | to the map of arguments of the object type. The execute function will extract the arguments of
-- | the field from the AST.
newtype ExecutableField a =
  ExecutableField { execute :: a -> AST.SelectionNode -> Either String Json.Json }

-- | Object types can have fields. Fields are constructed using the `field` function from this
-- | module and added to object types using the `:>` operator.
newtype Field a argsd argsp =
  Field
    { name :: String
    , description :: Maybe String
    , args :: Record argsd
    , serialize :: AST.SelectionNode -> Record argsp -> a -> Either String Json.Json
    }

-- | Fields can have multiple arguments. Arguments are constructed using the `arg` function from
-- | this module and the `?>` operator.
newtype Argument a =
  Argument
    { description :: Maybe String
    , parseLiteral :: AST.ValueNode -> Either String a
    , parseValue :: Json.Json -> Either String a
    }

-- | Creates an empty object type with the given name. Fields can be added to the object type using
-- | the `:>` operator from this module.
objectType :: forall a. String -> ObjectType a
objectType name =
  ObjectType { name, description: Nothing, fields: empty }

-- | Create a new field for an object type. This function is typically used together with the
-- | `:>` operator that automatically converts the field into an executable field.
field :: forall t a. OutputType t => String -> t a -> Field a () ()
field name t = Field { name, description: Nothing, args: {}, serialize: serialize' }
  where
    serialize' (AST.FieldNode node) _ val = serialize t node.selectionSet val
    serialize' _ _ _ = Left "Somehow obtained non FieldNode for field serialisation..."

-- | Create a tuple with a given name and a plain argument of the given type.
-- | The name argument tuple can then be used to be added to a field using the `?>` operator.
arg :: forall t a n. InputType t => IsSymbol n => t a -> SProxy n -> Tuple (SProxy n) (Argument a)
arg t name =
    Tuple (SProxy :: _ n) $
      Argument { description: Nothing, parseLiteral: parseL, parseValue: parseV }
  where
    parseL = parseLiteral t
    parseV = parseValue t

-- * Combinator operators

-- | The describe type class is used to allow adding descriptions to various parts of a GraphQL
-- | schema that can have a description. The `.>` operator can be used with the GraphQL object
-- | type DSL to easily add descriptions in various places.
-- |
-- | *Example:*
-- | ```purescript
-- | objectType "User"
-- |   .> "A user of the product."
-- |   :> "id" Scalar.id
-- |     .> "A unique identifier for this user."
-- | ```
class Describe a where
  describe :: a -> String -> a

infixl 8 describe as .>

instance describeObjectType :: Describe (ObjectType a) where
  describe (ObjectType config) s = ObjectType (config { description = Just s })

instance describeField :: Describe (Field a argsd argsp) where
  describe (Field config) s = Field (config { description = Just s })

instance describeArgument :: Describe (Argument a) where
  describe (Argument config) s = Argument (config { description = Just s })

-- | The `withField` function is used to add fields to an object type.
-- |
-- | When added to an object type the information about the field's argument are hidden in the
-- | closure by being converted to the `ExecutableField` type.
withField :: forall a argsd argsp.
  ArgsDefToArgsParam argsd argsp =>
  ObjectType a ->
  Field a argsd argsp ->
  ObjectType a
withField (ObjectType objectConfig) fld@(Field { name }) =
  ObjectType $ objectConfig { fields = insert name (makeExecutable fld) objectConfig.fields }
    where
      makeExecutable :: Field a argsd argsp -> ExecutableField a
      makeExecutable (Field { args, serialize: serialize' }) = ExecutableField { execute: execute' }
        where
          execute' :: a -> AST.SelectionNode -> Either String Json.Json
          execute' val node@(AST.FieldNode { arguments: argumentNodes }) = do
            argumentValues <- argsFromDefinition argumentNodes args
            serialize' node argumentValues val
          execute' _ _ = Left "Unexpected non field node field execution..."

-- | Add a field to an object type.
-- |
-- | *Example:*
-- | ```purescript
-- | objectType "Query"
-- |   :> field "hello" Scalar.string 
-- | ```
infixl 5 withField as :>

-- | A type class that contrains the relationship between defined arguments and the _argument_
-- | parameter of a resolver.
class ArgsDefToArgsParam (argsd :: # Type) (argsp :: # Type)
    | argsd -> argsp
    , argsp -> argsd where
      argsFromDefinition ::
        List AST.ArgumentNode ->
        Record argsd ->
        Either String (Record argsp)

instance argsDefToArgsParamImpl ::
  ( RL.RowToList argsd largsd
  , RL.RowToList argsp largsp
  , ArgsFromRows largsd largsp argsd argsp
  , RL.ListToRow largsd argsd
  , RL.ListToRow largsp argsp ) => ArgsDefToArgsParam argsd argsp where
    argsFromDefinition = argsFromRows (RLProxy :: RLProxy largsd) (RLProxy :: RLProxy largsp)

-- | ArgsDefToArgsParam that works on row lists for matching implementations
class ArgsFromRows
  (largsd :: RL.RowList)
  (largsp :: RL.RowList)
  (argsd :: # Type)
  (argsp :: # Type)
  where
    argsFromRows ::
      RLProxy largsd ->
      RLProxy largsp ->
      List AST.ArgumentNode ->
      Record argsd ->
      Either String (Record argsp)

instance argsFromRowsCons ::
  ( Row.Cons l (Argument a) targsd argsd
  , Row.Cons l a targsp argsp
  , Row.Lacks l targsd
  , Row.Lacks l targsp
  , ArgsFromRows ltargsd ltargsp targsd targsp
  , IsSymbol l ) =>
    ArgsFromRows
      (RL.Cons l (Argument a) ltargsd)
      (RL.Cons l a ltargsp)
      argsd
      argsp
        where
    argsFromRows argsdProxy argspProxy nodes argsd =
      let key = SProxy :: SProxy l
          Argument argConfig = Record.get key argsd
          tailArgsDef = Record.delete key argsd :: Record targsd
          nameEquals (AST.ArgumentNode { name: AST.NameNode { value } }) =
            value == reflectSymbol key
          argumentNode = find nameEquals nodes
          -- Extract the argument value if the node can be found. If not use null value
          -- TODO: Implement default values where we would try to use the default value first
          valueNode = maybe AST.NullValueNode (\(AST.ArgumentNode { value }) -> value) argumentNode
          tail = argsFromRows (RLProxy :: RLProxy ltargsd) (RLProxy :: RLProxy ltargsp) nodes tailArgsDef
      in Record.insert key <$> (argConfig.parseLiteral valueNode) <*> tail

else instance argsFromRowsNil :: ArgsFromRows RL.Nil RL.Nil argsd argsp where
  argsFromRows _ _ _ _ = pure $ unsafeCoerce {}

-- | The `withArgument` function adds an argument to a field. The argument can then be used in
-- | resolvers that are added to the field. The old resolver of the field is still valid until it is
-- | overwritten by `withResolver.`
withArgument :: forall a arg n argsdold argsdnew argspold argspnew.
  IsSymbol n =>
  Row.Cons n (Argument arg) argsdold argsdnew =>
  Row.Cons n arg argspold argspnew =>
  Row.Lacks n argsdold =>
  Row.Lacks n argspold =>
  ArgsDefToArgsParam argsdold argspold =>
  ArgsDefToArgsParam argsdnew argspnew =>
  Field a argsdold argspold ->
  Tuple (SProxy n) (Argument arg) ->
  Field a argsdnew argspnew
withArgument (Field fieldConfig) (Tuple proxy argument) =
  Field $ fieldConfig { args = args', serialize = serialize' }
    where
      args' :: Record argsdnew
      args' = Record.insert proxy argument fieldConfig.args

      serialize' :: AST.SelectionNode -> Record argspnew -> a -> Either String Json.Json
      serialize' node argsnew val = fieldConfig.serialize node (Record.delete proxy argsnew) val

-- | Adds an argument to a field that can be used in the resolver.
-- |
-- | *Example:*
-- | ```purescript
-- | objectType "Query"
-- |   :> field "hello" Scalar.string
-- |     ?> arg (SProxy :: SProxy "name") Scalar.string
-- |     !> (\{ name } parent -> "Hello " <> name <> "!")
-- | ```
infixl 7 withArgument as ?>

-- | The `withResolver` function adds a resolver to a field.
-- |
-- | _Note: When used multiple times on a field the resolvers are chained in front of each other._
withResolver :: forall a b argsd argsp. Field a argsd argsp -> (Record argsp -> b -> a) -> Field b argsd argsp
withResolver (Field fieldConfig) resolver =
  Field $ fieldConfig { serialize = serialize' }
    where 
      serialize' node args val = fieldConfig.serialize node args (resolver args val)

-- | Add a resolver to a field that receives the arguments in a record and the parent value.
-- |
-- | *Example:*
-- | ```purescript
-- | objectType "Query"
-- |   :> field "hello" Scalar.string
-- |     !> (\_ parent -> "Hello " <> parent.name <> "!")
-- | ```
infixl 6 withResolver as !>
