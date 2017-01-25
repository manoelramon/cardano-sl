module Explorer.State where

import Prelude
import Network.HTTP.Affjax (AJAX)
import DOM (DOM)

import Pux (EffModel, noEffects)
import Control.Monad.Eff.Class (liftEff)

import Explorer.Routes (Route(..))
import Explorer.I18n.Lang (Language(English))
import Explorer.Util.DOM (scrollTop)
import Explorer.Types (State, Action(..))


initialState :: State
initialState =
    { lang: English
    , route: Dashboard
    , count: 0
    }


-- update

update :: forall eff. Action -> State -> EffModel State Action (dom :: DOM, ajax :: AJAX | eff)
update Count state = noEffects $ state { count = state.count + 1 }
update (SetLanguage lang) state = noEffects $ state { lang = lang }
update (UpdateView route) state = routeEffects route (state { route = route })
update ScrollTop state = { state: state, effects: [ do
    _ <- liftEff $ scrollTop
    pure NoOp
  ]}
update NoOp state = noEffects state


-- routing

routeEffects :: forall eff. Route -> State -> EffModel State Action (dom :: DOM, ajax :: AJAX | eff)
routeEffects Dashboard state = { state, effects: [ pure ScrollTop ] }
routeEffects Transaction state = { state, effects: [ pure ScrollTop ] }
routeEffects Address state = { state, effects: [ pure ScrollTop ] }
routeEffects Calculator state = { state, effects: [ pure ScrollTop ] }
routeEffects Block state = { state, effects: [ pure ScrollTop ] }
routeEffects NotFound state = { state, effects: [ pure ScrollTop ] }
