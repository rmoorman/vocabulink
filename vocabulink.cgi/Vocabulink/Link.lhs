% Copyright 2008, 2009 Chris Forno

% This file is part of Vocabulink.

% Vocabulink is free software: you can redistribute it and/or modify it under
% the terms of the GNU Affero General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option) any
% later version.

% Vocabulink is distributed in the hope that it will be useful, but WITHOUT ANY
% WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
% A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
% details.

% You should have received a copy of the GNU Affero General Public License
% along with Vocabulink. If not, see <http://www.gnu.org/licenses/>.

\section{Links}

Links are the center of interest in our program. Most activities revolve around
them.

> module Vocabulink.Link (  Link(..), PartialLink(..), LinkType(..),
>                           getPartialLink, getLinkFromPartial, getLink,
>                           memberLinks, latestLinks, linkPage, deleteLink,
>                           linksPage, linksContainingPage, newLink,
>                           partialLinkHtml, partialLinkFromValues,
>                           drawLinkSVG, drawLinkSVG' ) where

> import Vocabulink.App
> import Vocabulink.CGI
> import Vocabulink.DB
> import Vocabulink.Html
> import Vocabulink.Review.Html
> import Vocabulink.Utils

> import Data.List (partition)
> import qualified Text.XHtml.Strict.Formlets as F

\subsection{Link Data Types}

Abstractly, a link is defined by the origin and destination lexemes it links,
as well as its type. Practically, we also need to carry around information such
as its link number (in the database) as well as a string representation of its
type (for partially constructed links, which you'll see later).

> data Link = Link {  linkNumber           :: Integer,
>                     linkTypeName         :: String,
>                     linkOrigin           :: String,
>                     linkOriginLang       :: String,
>                     linkDestination      :: String,
>                     linkDestinationLang  :: String,
>                     linkType             :: LinkType }

We can associate 2 lexemes in many different ways. Because different linking
methods require different information, they each need different representations
in the database. This leads to some additional complexity.

Each link between lexemes has a type. This type determines how the link is
displayed, edited, used in statistical analysis, etc. See the Vocabulink
handbook for a more in-depth description of the types.

> data LinkType =  Association | Cognate | LinkWord String String |
>                  Relationship String String
>                  deriving (Show)

Sometimes we need to work with a human-readable name, such as when interacting
with a client or the database.

> linkTypeNameFromType :: LinkType -> String
> linkTypeNameFromType Association         = "association"
> linkTypeNameFromType Cognate             = "cognate"
> linkTypeNameFromType (LinkWord _ _)      = "link word"
> linkTypeNameFromType (Relationship _ _)  = "relationship"

Each link type also has an associated color. This makes the type of links stand
out clearly in lists and graphs.

> linkColor :: Link -> String
> linkColor l = case linkTypeName l of
>                 "association"   -> "#000000"
>                 "cognate"       -> "#00AA00"
>                 "link word"     -> "#0000FF"
>                 "relationship"  -> "#AA0077"
>                 _               -> "#FF00FF"

The link's background color is used for shading and highlighting.

> linkBackgroundColor :: Link -> String
> linkBackgroundColor l = case linkTypeName l of
>                 "association"   -> "#DFDFDF"
>                 "cognate"       -> "#DFF4DF"
>                 "link word"     -> "#DFDFFF"
>                 "relationship"  -> "#F4DFEE"
>                 _               -> "#FFDFFF"

Links are created by members. Vocabulink does not own them. It merely has a
license to use them (as part of the Terms of Use). So when displaying a link in
full, we display a copyright notice with the member's username.

> linkCopyright :: Link -> App String
> linkCopyright l = do
>   t <- queryTuple'  "SELECT username, \
>                            \extract(year from created), \
>                            \extract(year from updated) \
>                     \FROM link, member \
>                     \WHERE member_no = author AND link_no = ?"
>                     [toSql $ linkNumber l]
>   return $ "© " ++ case t of
>                      Just [a,c,u]  ->  let c'  = show (fromSql c :: Integer)
>                                            u'  = show (fromSql u :: Integer)
>                                            r   = c' == u' ? c' $ c' ++ "–" ++ u' in
>                                        r ++ " " ++ (fromSql a)
>                      _             ->  "unknown"

Fully loading a link from the database requires joining 2 relations. The join
depends on the type of the link. But we don't always need the type-specific
data associated with a link. Sometimes it's not even possible to have it, such
as during interactive link construction.

We'll use a separate type to represent this. Essentially it's a link with an
undefined linkType. We use a separate type to avoid passing a partial link to a
function that expects a fully-instantiated link. The only danger here is
writing a function that accepts a partial link and then trys to access the
linkType information.

> newtype PartialLink = PartialLink { pLink :: Link }

\subsection{Storing Links}

We refer to storing a link as ``establishing'' the link.

Each link type is expected to be potentially different enough to require its
own database schema for representation. We could attempt to use PostgreSQL's
inheritance features, but I've decided to handle the difference between types
at the Haskell layer for now. I'm actually hesitant to use separate tables for
separate types as it feels like I'm breaking the relational model. However, any
extra efficiency for study outranks implementation elegance (correctness?).

Establishing a link requires a member number since all links must be owned by a
member.

Since we need to store the link in 2 different tables, we use a transaction.
Our App-level database functions are not yet great with transactions, so we'll
have to handle the transaction manually here. You'll also notice that some link
types (such as cognates) have no additional information and hence no relation
in the database.

This returns the newly established link number.

> establishLink :: Link -> Integer -> App (Maybe Integer)
> establishLink l memberNo = do
>   r <- withTransaction' $ do
>     c <- asks appDB
>     linkNo <- liftIO $ insertNo c
>       "INSERT INTO link (origin, destination, \
>                         \origin_language, destination_language, \
>                         \link_type, author) \
>                 \VALUES (?, ?, ?, ?, ?, ?)"
>       [  toSql (linkOrigin l), toSql (linkDestination l),
>          toSql (linkOriginLang l), toSql (linkDestinationLang l),
>          toSql (linkTypeName l), toSql memberNo ]
>       "link_link_no_seq"
>     case linkNo of
>       Nothing  -> liftIO $ rollback c >> return Nothing
>       Just n   -> do  establishLinkType (l {linkNumber = n})
>                       return linkNo
>   return $ fromMaybe Nothing r

The relation we insert additional details into depends on the type of the link
and it's easiest to use a separate function for it.

> establishLinkType :: Link -> App ()
> establishLinkType l = case linkType l of
>   Association                -> return ()
>   Cognate                    -> return ()
>   (LinkWord word story)      -> do
>     run'  "INSERT INTO link_type_link_word (link_no, link_word, story) \
>                                    \VALUES (?, ?, ?)"
>           [toSql (linkNumber l), toSql word, toSql story]
>     return ()
>   (Relationship left right)  -> do
>     run'  "INSERT INTO link_type_relationship \
>                  \(link_no, left_side, right_side) \
>           \VALUES (?, ?, ?)"
>           [toSql (linkNumber l), toSql left, toSql right]
>     return ()

\subsection{Retrieving Links}

Now that we've seen how we store links, let's look at retrieving them (which is
slightly more complicated in order to allow for efficient retrieval of multiple
links).

Retrieving a partial link is simple.

> getPartialLink :: Integer -> App (Maybe PartialLink)
> getPartialLink linkNo = do
>   t <- queryTuple'  "SELECT link_no, link_type, origin, destination, \
>                            \origin_language, destination_language \
>                     \FROM link WHERE link_no = ?" [toSql linkNo]
>   return $ partialLinkFromValues =<< t

We use a helper function to convert the raw SQL tuple to a partial link value.
Note that we leave the link's |linkType| undefined.

> partialLinkFromValues :: [SqlValue] -> Maybe PartialLink
> partialLinkFromValues [n, t, o, d, ol, dl] = Just $
>   PartialLink $ Link {  linkNumber           = fromSql n,
>                         linkTypeName         = fromSql t,
>                         linkOrigin           = fromSql o,
>                         linkDestination      = fromSql d,
>                         linkOriginLang       = fromSql ol,
>                         linkDestinationLang  = fromSql dl,
>                         linkType             = undefined }
> partialLinkFromValues _  = Nothing

Once we have a partial link, it's a simple matter to turn it into a full link.
We just need to retrieve its type-level details from the database.

> getLinkFromPartial :: PartialLink -> App (Maybe Link)
> getLinkFromPartial (PartialLink partial) = do
>   linkT <- getLinkType (PartialLink partial)
>   return $ (\t -> Just $ partial {linkType = t}) =<< linkT

> getLinkType :: PartialLink -> App (Maybe LinkType)
> getLinkType (PartialLink p) = case p of
>   (Link {  linkTypeName  = "association" })  -> return $ Just Association
>   (Link {  linkTypeName  = "cognate"})       -> return $ Just Cognate
>   (Link {  linkTypeName  = "link word",
>            linkNumber    = n })              -> do
>     rs <- queryTuple'  "SELECT link_word, story FROM link_type_link_word \
>                        \WHERE link_no = ?" [toSql n]
>     case rs of
>       Just [linkWord, story]  -> return $ Just $
>         LinkWord (fromSql linkWord) (fromSql story)
>       _                       -> return Nothing
>   (Link {  linkTypeName  = "relationship",
>            linkNumber    = n })              -> do
>     rs <- queryTuple'  "SELECT left_side, right_side \
>                        \FROM link_type_relationship \
>                        \WHERE link_no = ?" [toSql n]
>     case rs of
>       Just [left, right]  -> return $ Just $
>         Relationship (fromSql left) (fromSql right)
>       _                   -> return Nothing
>   _                                         -> error "Bad partial link."

We now have everything we need to retrieve a full link in 1 step.

> getLink :: Integer -> App (Maybe Link)
> getLink linkNo = do
>   l <- getPartialLink linkNo
>   maybe (return Nothing) getLinkFromPartial l

We already know what types of links exist, but we want only the active link
types (some, like Relationship, are experimental) sorted by how common they
are.

> activeLinkTypes :: [String]
> activeLinkTypes = ["link word", "association", "cognate"]

\subsection{Deleting Links}

Links can be deleted by their owner. They're not actually removed from the
database, as doing so would require removing the link from other members'
review sets. Instead, we just flag the link as deleted so that it doesn't
appear in most contexts.

> deleteLink :: Integer -> App CGIResult
> deleteLink linkNo = do
>   res  <- quickStmt'  "UPDATE link SET deleted = TRUE \
>                       \WHERE link_no = ?" [toSql linkNo]
>   case res of
>     Nothing  -> error "Failed to delete link."
>     Just _   -> redirect =<< referrerOrVocabulink

\subsection{Displaying Links}

Drawing links is a rather complicated process due to the limitations of HTML.
Fortunately there is Raphaël (http://raphaeljs.com/reference.html) which makes
some pretty fancy link drawing possible via JavaScript. You'll need to make
sure to include both |JS "raphael"| and |JS "link-graph"| as dependencies when
using this.

> drawLinkSVG :: Link -> Html
> drawLinkSVG = drawLinkSVG' "drawLink"

> drawLinkSVG' :: String -> Link -> Html
> drawLinkSVG' f link = script << primHtml (
>   "connect(window, 'onload', partial(" ++ f ++ "," ++
>   showLinkJSON link ++ "));") +++
>   thediv ! [identifier "graph", thestyle "height: 100px"] << noHtml

It seems that the JSON library author does not want us making new instances of
the |JSON| class. Oh well, I didn't want to write |readJSON| anyway.

> showLinkJSON :: Link -> String
> showLinkJSON link =  let obj = [  ("orig", linkOrigin link),
>                                   ("dest", linkDestination link),
>                                   ("color", linkColor link),
>                                   ("bgcolor", linkBackgroundColor link),
>                                   ("label", linkLabel $ linkType link)] in
>                      encode $ toJSObject obj
>                        where linkLabel (LinkWord word _)  = word
>                              linkLabel _                  = ""

Displaying an entire link involves not just drawing a graphical representation
of the link but displaying its type-level details as well.

> displayLink :: Link -> Html
> displayLink l = concatHtml [
>   drawLinkSVG l,
>   thediv ! [theclass "link-details"] << linkTypeHtml (linkType l) ]

> linkTypeHtml :: LinkType -> Html
> linkTypeHtml Association = noHtml
> linkTypeHtml Cognate = noHtml
> linkTypeHtml (LinkWord _ story) =
>   markdownToHtml story
> linkTypeHtml (Relationship leftSide rightSide) =
>   paragraph ! [thestyle "text-align: center"] << [
>     stringToHtml "as", br,
>     stringToHtml $ leftSide ++ " → " ++ rightSide ]

Sometimes we don't need to display all of a links details. This displays a
partial link more compactly, such as for use in lists, etc.

> partialLinkHtml :: PartialLink -> Html
> partialLinkHtml (PartialLink l) =
>   anchor ! [  href ("/link/" ++ (show $ linkNumber l)),
>               thestyle $  "color: " ++ linkColor l ++
>                           "; background-color: " ++ linkBackgroundColor l ++
>                           "; border: 1px solid " ++ linkColor l ] <<
>     (linkOrigin l ++ " → " ++ linkDestination l)

Each link gets its own URI and page. Most of the extra code in the following is
for handling the display of link operations (``review'', ``delete'', etc.),
dealing with retrieval exceptions, etc.

> linkPage :: Integer -> App CGIResult
> linkPage linkNo = do
>   memberNo <- asks appMemberNo
>   l <- getLink linkNo
>   case l of
>     Nothing  -> output404 ["link", show linkNo]
>     Just l'  -> do
>       review <- reviewIndicator linkNo
>       owner <- queryValue'  "SELECT author = ? FROM link WHERE link_no = ?"
>                             [toSql memberNo, toSql linkNo]
>       ops <- linkOperations linkNo $ maybe False fromSql owner
>       copyright <- linkCopyright l'
>       let orig  = linkOrigin l'
>           dest  = linkDestination l'
>       stdPage (orig ++ " -> " ++ dest) [
>         CSS "link", JS "MochiKit", JS "raphael", JS "link-graph"] []
>         [  drawLinkSVG l',
>            thediv ! [theclass "link-ops"] << [review, ops],
>            thediv ! [theclass "link-details"] << linkTypeHtml (linkType l'),
>            paragraph ! [theclass "copyright"] << copyright ]

Each link can be ``operated on''. It can be reviewed (added to the member's
review set) and deleted (marked as deleted). In the future, I expect operations
such as ``tag'', ``rate'', etc.

> linkOperations :: Integer -> Bool -> App Html
> linkOperations n True   = do
>   deleted <- queryValue'  "SELECT deleted FROM link \
>                           \WHERE link_no = ?" [toSql n]
>   return $ case deleted of
>     Just d  -> if fromSql d
>       then paragraph << "Deleted"
>       else form ! [action ("/link/" ++ (show n) ++ "/delete"), method "POST"] <<
>              submit "" "Delete"
>     _       -> stringToHtml
>                  "Can't determine whether or not link has been deleted."
> linkOperations _ False  = return noHtml

\subsection{Finding Links}

While Vocabulink is still small, it makes sense to have a page just for
displaying all the (non-deleted) links in the system. This will probably go
away eventually.

> linksPage :: String -> (Int -> Int -> App (Maybe [PartialLink])) -> App CGIResult
> linksPage title f = do
>   (pg, n, offset) <- currentPage
>   ts <- f offset (n + 1)
>   case ts of
>     Nothing  -> error "Error while retrieving links."
>     Just ps  -> do
>       pagerControl <- pager pg n $ offset + (length ps)
>       simplePage title [CSS "link"] [
>         unordList (map partialLinkHtml (take n ps)) !
>           [identifier "central-column", theclass "links"],
>         pagerControl ]

A more practical option for the long run is providing search. ``Containing''
search is a search for links that ``contain'' the given ``focus'' lexeme on one
side or the other of the link. The term ``containing'' is a little misleading
and should be changed at some point.

For now we use exact matching only as that can use an index. Fuzzy matching is
going to require configuring full text search or a separate search daemon.

> linksContainingPage :: String -> App CGIResult
> linksContainingPage focus = do
>   ts <- queryTuples'  "SELECT link_no, link_type, origin, destination, \
>                              \origin_language, destination_language \
>                       \FROM link \
>                       \WHERE NOT deleted \
>                         \AND (origin LIKE ? OR destination LIKE ?) \
>                       \LIMIT 20"
>                       [toSql focus, toSql focus]
>   case ts of
>     Nothing  -> error "Error while retrieving links."
>     Just ls  -> simplePage (  "Found " ++ (show $ length ls) ++
>                               " link" ++ (length ls == 1 ? "" $ "s") ++ 
>                               " containing \"" ++ focus ++ "\"")
>                   [  CSS "link",
>                      JS "MochiKit", JS "raphael", JS "link-graph"]
>                   (linkFocusBox focus (catMaybes $ map partialLinkFromValues ls))

When the links containing a search term have been found, we need a way to
display them. We do so by drawing a ``link graph'': a circular array of links.

Before we can display the graph, we need to sort the links into ``links
containing the focus as the origin'' and ``links containing the focus as the
destination''.

If you're trying to understand this function, it helps to read the JavaScript
it outputs and digest each local function separately.

> linkFocusBox :: String -> [PartialLink] -> [Html]
> linkFocusBox focus links = [
>   script << primHtml
>     (  "connect(window, 'onload', partial(drawLinks," ++
>        encode focus ++ "," ++
>        jsonNodes ("/link?input2=" ++ focus) origs ++ "," ++
>        jsonNodes ("/link?input0=" ++ focus) dests ++ "));" ),
>   thediv ! [identifier "graph"] << noHtml ]
>  where partitioned   = partition ((== focus) . linkOrigin . pLink) links
>        origs         = snd partitioned
>        dests         = fst partitioned
>        jsonNodes url xs  = encode $ insertMid
>          (toJSObject [  ("orig",   "new link"),
>                         ("dest",   "new link"),
>                         ("color",  "#000000"),
>                         ("bgcolor", "#DFDFDF"),
>                         ("style",  "dotted"),
>                         ("url",    url) ])
>          (map (\o ->  let o' = pLink o in
>                       toJSObject [  ("orig",     linkOrigin o'),
>                                     ("dest",     linkDestination o'),
>                                     ("color",    linkColor $ pLink o),
>                                     ("bgcolor",  linkBackgroundColor $ pLink o),
>                                     ("number",   show $ linkNumber $ pLink o)]) xs)
>        insertMid :: a -> [a] -> [a]
>        insertMid x xs = let (l,r) = foldr (\a ~(x',y') -> (a:y',x')) ([],[]) xs in
>                         reverse l ++ [x] ++ r

\subsection{Creating New Links}

We want the creation of new links to be as simple as possible. For now, it's
done on a single page. The form on the page dynamically updates (via
JavaScript, but not AJAX) based on the type of the link being created.

This is very large because it handles generating the form, previewing the
result, and dispatching the creation of the link on successful form validation.

> newLink :: App CGIResult
> newLink = withRequiredMemberNumber $ \memberNo -> do
>   uri   <- requestURI
>   meth  <- requestMethod
>   preview <- getInput "preview"
>   establishF <- establish activeLinkTypes
>   (status, xhtml) <- runForm' establishF
>   case preview of
>     Just _  -> do
>       let preview' = case status of
>                        Failure failures  -> unordList failures
>                        Success link      -> thediv ! [theclass "preview"] <<
>                                               displayLink link
>       simplePage "Create a Link (preview)" deps
>         [  preview',
>            form ! [  thestyle "text-align: center",
>                      action (uriPath uri), method "POST"] <<
>              [xhtml, actionBar] ]
>     Nothing -> do
>       case status of
>         Failure failures  -> simplePage "Create a Link" deps
>           [  form ! [  thestyle "text-align: center",
>                        action (uriPath uri), method "POST"] <<
>                [  meth == "GET" ? noHtml $ unordList failures,
>                   xhtml, actionBar ] ]
>         Success link -> do
>           linkNo <- establishLink link memberNo
>           case linkNo of
>             Just n   -> redirect $ "/link/" ++ (show n)
>             Nothing  -> error "Failed to establish link."
>  where deps = [  CSS "link", JS "MochiKit", JS "link",
>                  JS "raphael", JS "link-graph"]
>        actionBar = thediv ! [thestyle "margin-left: auto; margin-right: auto; \
>                                       \width: 12em"] <<
>                      [  submit "preview" "Preview" !
>                           [thestyle "float: left; width: 5.5em"],
>                         submit "" "Link" ! [thestyle "float: right; width: 5.5em"],
>                         paragraph ! [thestyle "clear: both"] << noHtml ]

Here's a form for creating a link. It gathers all of the required details
(origin, destination, and link type details).

> establish :: [String] -> App (AppForm Link)
> establish ts = do
>   originPicker       <- languagePicker $ Left ()
>   destinationPicker  <- languagePicker $ Right ()
>   return (mkLink  <$> lexemeInput "Origin"
>                   <*> plug (+++ stringToHtml " ") originPicker
>                   <*> lexemeInput "Destination"
>                   <*> destinationPicker
>                   <*> linkTypeInput ts)

When creating a link from a form, the link number must be undefined until the
link is established in the database. Also, because of the way formlets work (or
how I'm using them), we need to retrieve the link type name from the link type.

> mkLink :: String -> String -> String -> String -> LinkType -> Link
> mkLink o ol d dl t = Link {  linkNumber           = undefined,
>                              linkTypeName         = linkTypeNameFromType t,
>                              linkOrigin           = o,
>                              linkOriginLang       = ol,
>                              linkDestination      = d,
>                              linkDestinationLang  = dl,
>                              linkType             = t }

The lexeme is the origin or destination of the link.

> lexemeInput :: String -> AppForm String
> lexemeInput l = l `formLabel` F.input Nothing `check` ensures
>   [  ((/= "")           , l ++ " is required."),
>      ((<= 64) . length  , l ++ " must be 64 characters or shorter.") ]

Each lexeme needs to be annotated with its language (to aid with
disambiguation, searching, and sorting). Most members are going to be studying
a single language, and it would be cruel to make them scroll through a huge
list of languages each time they wanted to create a new link. So what we do is
sort languages that the member has already used to the top of the list (based
on frequency).

This takes an either parameter to signify whether you want origin language
(Left) or destination language (Right). They are sorted separately.

> languagePicker :: Either () () -> App (AppForm String)
> languagePicker side = do
>   let side' = case side of
>                 Left _   -> "origin"
>                 Right _  -> "destination"
>   memberNo <- asks appMemberNo
>   langs <- (map pairUp) . fromJust <$> queryTuples'
>              ("SELECT " ++ side' ++ "_language, name \
>               \FROM link, language \
>               \WHERE language.abbr = link." ++ side' ++ "_language \
>                 \AND link.author = ? \
>               \GROUP BY " ++ side' ++ "_language, name \
>               \ORDER BY COUNT(" ++ side' ++ "_language) DESC")
>              [toSql memberNo]
>   allLangs <- (map pairUp) . fromJust <$> queryTuples'
>                 "SELECT abbr, name FROM language ORDER BY abbr" []
>   let choices = langs ++ [("","")] ++ allLangs
>   return $ F.select choices (Just $ fst . head $ choices) `check` ensures
>              [  ((/= "")  ,  side' ++ " language is required") ]
>  where pairUp :: [SqlValue] -> (String,String)
>        pairUp [x,y]  = (fromSql x, fromSql y)
>        pairUp _      = error "Invalid pair."

We have a bit of a challenge with link types. We want the form to adjust
dynamically using JavaScript when a member chooses one of the link types from a
select list. But we also want form validation using formlets. Formlets would be
rather straightforward if we were using a 2-step process (choose the link type,
submit, fill in the link details, submit). But it's important to keep the link
creation process simple (and hence 1-step).

The idea is to generate all the form fields for every possible link type in
advance, with a default hidden state. Then JavaScript will reveal the
appropriate fields when a link type is chosen. Upon submit, all link type
fields for all but the selected link type will be empty (or unnecessary). When
running the form, we will instantiate all of them, but then |linkTypeS| will
select just the appropriate one based on the @<select>@.

The main challenge here is that we can't put the validation in the link types
themselves. We have to move it into |linkTypeInput|. The problem comes from
either my lack of understanding of Applicative Functors, or the fact that by
the time the formlet combination strategy (Failure) runs, the unused link types
have already generated failure because they have no way of knowing if they've
been selected (``idioms are ignorant'').

I'm deferring a proper implementation until it's absolutely necessary.
Hopefully by then I will know more than I do now.

> linkTypeInput :: [String] -> AppForm LinkType
> linkTypeInput ts = (linkTypeS  <$> plug (\xhtml ->
>                                            paragraph << [  xhtml,
>                         helpButton "/article/understanding-link-types" Nothing])
>                                      ("Link Type" `formLabel` linkSelect Nothing)
>                                <*> pure Association
>                                <*> pure Cognate
>                                <*> fieldset' "link-word" linkTypeLinkWord
>                                <*> fieldset' "relationship" linkTypeRelationship)
>                    `check` ensure complete
>                      "Please fill in all the link type fields."
>   where linkSelect = F.select $ zip ts ts
>         complete Association         = True
>         complete Cognate             = True
>         complete (LinkWord w s)      = (w /= "") && (s /= "")
>         complete (Relationship l r)  = (l /= "") && (r /= "")
>         fieldset' ident              = plug
>           (fieldset ! [identifier ident, thestyle "display: none"] <<)

> linkTypeS :: String -> LinkType -> LinkType -> LinkType -> LinkType -> LinkType
> linkTypeS "association"   l _ _ _ = l
> linkTypeS "cognate"       _ l _ _ = l
> linkTypeS "link word"     _ _ l _ = l
> linkTypeS "relationship"  _ _ _ l = l
> linkTypeS _ _ _ _ _ = error "Unknown link type."

> linkTypeLinkWord :: AppForm LinkType
> linkTypeLinkWord = LinkWord  <$> "Link Word" `formLabel'` F.input Nothing
>   <*> F.textarea (Just "Write a story linking the 2 words here.")

> linkTypeRelationship :: AppForm LinkType
> linkTypeRelationship = Relationship <$>
>   plug (+++ stringToHtml " is to ") (F.input Nothing) <*> F.input Nothing

We want to be able to display links in various ways. It would be really nice to
get lazy lists from the database. However, lazy HDBC results don't seem to work
too well in my experience (at least not with PostgreSQL). For now, you need to
specify how many results you want, as well as an offset.

Here we retrieve multiple links at once. This was the original motivation for
dividing link types into full and partial. Often we need to retrieve links for
simple display but we don't need or want extra trips to the database. Here we
need only 1 query instead of potentially @limit@ queries.

We don't want to display deleted links (which are left in the database for
people still reviewing them). There is some duplication of SQL here, but I have
yet found a nice way to generalize these functions.

The first way to retrieve links is to just grab all of them, starting at the
most recent. This assumes the ordering of links is determined by link number.

> latestLinks :: Int -> Int -> App (Maybe [PartialLink])
> latestLinks offset limit = do
>   ts <- queryTuples'  "SELECT link_no, link_type, origin, destination, \
>                              \origin_language, destination_language \
>                       \FROM link WHERE NOT deleted \
>                       \ORDER BY link_no DESC \
>                       \OFFSET ? LIMIT ?" [toSql offset, toSql limit]
>   return $ (catMaybes . map partialLinkFromValues) `liftM` ts

Another way we retrieve links is by author (member). These just happen to be
sorted by link number as well.

> memberLinks :: Integer -> Int -> Int -> App (Maybe [PartialLink])
> memberLinks memberNo offset limit = do
>   ts <- queryTuples'  "SELECT link_no, link_type, origin, destination, \
>                              \origin_language, destination_language \
>                       \FROM link \
>                       \WHERE NOT deleted AND author = ? \
>                       \ORDER BY link_no DESC \
>                       \OFFSET ? LIMIT ?"
>                       [toSql memberNo, toSql offset, toSql limit]
>   return $ (catMaybes . map partialLinkFromValues) `liftM` ts

