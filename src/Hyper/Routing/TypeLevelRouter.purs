-- Highly experimental and naive implementation of servant-server style
-- routing for Hyper. Not much will be stable, nor usable, here.
module Hyper.Routing.TypeLevelRouter where

import Prelude
import Control.Monad.Error.Class (throwError)
import Data.Array (elem, filter, foldl, null, uncons)
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Eq (genericEq)
import Data.Generic.Rep.Show (genericShow)
import Data.Int (fromString)
import Data.Maybe (Maybe(..))
import Data.Monoid (class Monoid, mempty)
import Data.Newtype (class Newtype)
import Data.Path.Pathy (dir, rootDir, (</>))
import Data.String (Pattern(..), split)
import Data.Symbol (class IsSymbol, SProxy(..), reflectSymbol)
import Data.URI (HierarchicalPart(..), URI(..))
import Type.Proxy (Proxy(..))

data Lit (v :: Symbol)
data Capture (v :: Symbol) t

data Verb (m :: Symbol) (ct :: Symbol)

type Get ct = Verb "GET" ct

data Sub e t
data LitSub (v :: Symbol) t
data Endpoints a b = Endpoints a b

infixr 5 type Sub as :>
infixr 5 type LitSub as :/
infixl 4 type Endpoints as :<|>
infixl 4 Endpoints as :<|>

newtype Link = Link (Array String)

instance monoidLink :: Monoid Link where
  mempty = Link []

instance semigroupLink :: Semigroup Link where
  append (Link p1) (Link p2) = Link (p1 <> p2)

derive instance newtypeLink :: Newtype Link _

derive instance genericLink :: Generic Link _

instance eqLink :: Eq Link where
  eq = genericEq

linkToURI :: Link -> URI
linkToURI (Link segments) =
  URI
  Nothing
  (HierarchicalPart
   Nothing
   (Just (Left (foldl (</>) rootDir (map dir segments)))))
  Nothing
  Nothing

class ToHttpData x where
  toPathPiece :: x -> String

instance toHttpDataInt :: ToHttpData Int where
  toPathPiece = show

class FromHttpData x where
  fromPathPiece :: String -> Either String x

instance fromHttpDataInt :: FromHttpData Int where
  fromPathPiece s =
    case fromString s of
      Just n -> Right n
      Nothing -> Left ("Invalid Int: " <> s)

class HasLink e mk | e -> mk where
  toLink :: Proxy e -> Link -> mk

instance hasLinkLit :: (HasLink sub subMk, IsSymbol lit)
                       => HasLink (Lit lit :> sub) subMk where
  toLink _ =
    toLink (Proxy :: Proxy sub) <<< flip append (Link [segment])
    where
      segment = reflectSymbol (SProxy :: SProxy lit)

instance hasLinkLitSub :: (HasLink sub subMk, IsSymbol lit)
                          => HasLink (lit :/ sub) subMk where
  toLink _ = toLink (Proxy :: Proxy (Lit lit :> sub))

instance hasLinkCapture :: (HasLink sub subMk, IsSymbol c, ToHttpData t)
                           => HasLink (Capture c t :> sub) (t -> subMk) where
  toLink _ l (x :: t) =
    toLink (Proxy :: Proxy sub) $ append l (Link [toPathPiece x])

instance hasLinkVerb :: HasLink (Verb m ct) URI where
  toLink _ = linkToURI

linkTo :: forall l t. HasLink l t => Proxy l -> t
linkTo p = toLink p mempty

type RoutingContext = { path :: (Array String)
                      , method :: String
                      }

data RoutingError
  = HTTPError Int (Maybe String)

derive instance genericRoutingError :: Generic RoutingError _

instance eqRoutingError :: Eq RoutingError where
  eq = genericEq

instance showRoutingError :: Show RoutingError where
  show = genericShow

class Router e h r | e -> h, e -> r where
  route :: Proxy e -> RoutingContext -> h -> Either RoutingError r

fallthrough :: RoutingError -> Boolean
fallthrough (HTTPError code _) = code `elem` [404, 405]

instance routerEndpoints :: (Router e1 h1 out, Router e2 h2 out)
                            => Router (e1 :<|> e2) (h1 :<|> h2) out where
  route _ context (h1 :<|> h2) =
    case route (Proxy :: Proxy e1) context h1 of
      Left err ->
        if fallthrough err
        then route (Proxy :: Proxy e2) context h2
        else Left err
      Right handler -> pure handler

instance routerLit :: (Router e h out, IsSymbol lit)
                      => Router (Lit lit :> e) h out where
  route _ ctx r =
    case uncons ctx.path of
      Just { head, tail } | head == expectedSegment ->
        route (Proxy :: Proxy e) ctx { path = tail} r
      Just _ -> throwError (HTTPError 404 Nothing)
      Nothing -> throwError (HTTPError 404 Nothing)
    where expectedSegment = reflectSymbol (SProxy :: SProxy lit)

instance routerLitSub :: (Router e h out, IsSymbol lit)
                         => Router (lit :/ e) h out where
  route _ = route (Proxy :: Proxy (Lit lit :> e))

instance routerCapture :: (Router e h out, FromHttpData v)
                          => Router (Capture c v :> e) (v -> h) out where
  route _ ctx r =
    case uncons ctx.path of
      Nothing -> throwError (HTTPError 404 Nothing)
      Just { head, tail } ->
        case fromPathPiece head of
          Left err -> throwError (HTTPError 400 (Just err))
          Right x -> route (Proxy :: Proxy e) ctx { path = tail } (r x)

instance routerVerb :: (IsSymbol m)
                       => Router (Verb m ct) h h where
  route _ context r =
    if expectedMethod == context.method && null context.path
    then pure r
    else throwError (HTTPError 405 (Just ("Method "
                                          <> context.method
                                          <> " did not match "
                                          <> expectedMethod)))
    where
      expectedMethod = reflectSymbol (SProxy :: SProxy m)

runRouter
  :: forall s r a.
     Router s r a
     => Proxy s
     -> r
     -> String
     -> String
     -> Either RoutingError a
runRouter _ handler method url =
  route (Proxy :: Proxy s) { path: p, method: method } handler
  where
    p = filter ((/=) "") (split (Pattern "/") url)
