-- Copyright 2011 Chris Forno

-- This file is part of Vocabulink.

-- Vocabulink is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version.

-- Vocabulink is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
-- for more details.

-- You should have received a copy of the GNU Affero General Public License
-- along with Vocabulink. If not, see <http://www.gnu.org/licenses/>.

module Vocabulink.Link.Pronunciation (pronounceable, addPronunciation, getPronunciations) where

import Vocabulink.App
import Vocabulink.CGI
import Vocabulink.Utils

import Network.Curl.Download.Lazy (openLazyURI)
import Network.Curl.Download (openURIString)

import Prelude hiding (writeFile)

pronounceable :: Integer -> App Bool
pronounceable linkNo = do
  f <- pronunciationFile linkNo "ogg"
  liftIO $ isFileReadable f

pronunciationFile :: Integer -> String -> App FilePath
pronunciationFile linkNo filetype = do
  -- This pronunciation has not technically been uploaded, but we'll keep it
  -- the upload directory for now.
  dir <- (</> "upload" </> "audio" </> "pronunciation") <$> asks appDir
  return $ dir </> show linkNo <.> filetype

addPronunciation :: Integer -> String -> String -> App (Either String ())
addPronunciation linkNo url filetype = do
  audio <- liftIO $ openLazyURI url
  case audio of
    Left s  -> return $ Left s
    Right a -> saveFile a >> return (Right ())
 where saveFile s = do
         f <- pronunciationFile linkNo filetype
         liftIO $ writeFile f s

getPronunciations :: String -> String -> App CGIResult
getPronunciations lang word = do
  key <- asks appForvoKey
  let url = ("http://apifree.forvo.com/key/" ++ key
          ++ "/format/json/action/word-pronunciations/word/"
          ++ escapeURIString (\ _ -> False) (encodeString word)
          ++ "/language/" ++ lang ++ "/order/rate-desc")
  s <- liftIO $ openURIString url
  case s of
    Left _   -> error "Unable to retrieve pronunciations"
    Right s' -> outputText s'
