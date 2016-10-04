{-|
Module: ScaledImage
Description: Scalable, positionable image widget
Copyright: (c) Greg Hale, 2016
License: BSD3
Maintainer: imalsogreg@gmail.com
Stability: experimental
Portability: GHCJS

This module provides a reflex-dom widget for scaling and positioning images.

A top-level div defaults to the natural size of a source image. The @topScale@
config parameter adjusts the size of this container.

@sicSetOffset@, @sicSetScale@, and @sicSetBounding@ allow the image to be
offset, scaled, and cropped while holding the top-level div's size constant.
The crop is in dimensions of the natural size of the image
(cropping an 10x10 pixel image by 5 pixels will always result in a picture cut in half)

@imageSpace*@ properties transform various mouse events to the coordinate
frame of the original imaage.
-}

{-# language BangPatterns #-}
{-# language CPP #-}
{-# language FlexibleContexts #-}
{-# language GADTs #-}
{-# language RecursiveDo #-}
{-# language KindSignatures #-}
{-# language LambdaCase #-}
{-# language OverloadedStrings #-}
{-# language RankNTypes #-}
{-# language TypeFamilies #-}
{-# language ScopedTypeVariables #-}

module ScaledImage (

  ScaledImageConfig(..),
  ScaledImage(..),
  scaledImage,
  BoundingBox (..),
  Coord(..),
  fI,
  r2,
  CanvasRenderingContext2D(..),
  ImageData(..),
  ClientRect(..),
  getWidth,
  getHeight,
  getBoundingClientRect,
  divImgSpace',
  divImgSpace,
  wheelEvents
)where

import           Control.Monad            (liftM2)
import           Control.Monad.IO.Class   (MonadIO, liftIO)
import           Data.Bool
import           Data.Default             (Default, def)
import           Data.Map                 (Map)
import qualified Data.Map                 as Map
import           Data.Maybe               (fromMaybe)
import           Data.Monoid              ((<>))
import qualified Data.Text                as T
import           Reflex.Dom               hiding (restore)
#ifdef ghcjs_HOST_OS
import GHCJS.DOM.HTMLCanvasElement        (getContext, castToHTMLCanvasElement)
import GHCJS.DOM.CanvasRenderingContext2D (CanvasRenderingContext2D, save, restore, getImageData)
import           GHCJS.DOM.Types          (ImageData, ClientRect, Nullable, nullableToMaybe)
import           GHCJS.Marshal            (fromJSValUnchecked, toJSVal)
import           GHCJS.DOM.Element        (getBoundingClientRect, getClientTop, getClientLeft)
import           GHCJS.DOM.ClientRect     (getTop, getLeft, getWidth, getHeight)
#endif
import           GHCJS.DOM.Types          (IsGObject, HTMLCanvasElement, HTMLImageElement)
import           GHCJS.DOM.CanvasRenderingContext2D as Context2D
import qualified GHCJS.DOM.HTMLImageElement as ImageElement
import           GHCJS.DOM.EventM         (on, event, stopPropagation, preventDefault)
import qualified GHCJS.DOM.ClientRect     as CR
import           GHCJS.DOM.Element        (getClientTop, getClientLeft)
import           GHCJS.DOM.MouseEvent     (getClientX, getClientY)
import qualified GHCJS.DOM.Types          as GT
import           GHCJS.DOM.WheelEvent     as WheelEvent
import qualified GHCJS.DOM.Element        as E


data Coord = Coord
  { coordX :: !Double
  , coordY :: !Double
  } deriving (Eq, Show, Ord, Read)

data BoundingBox = BoundingBox
  { bbTopLeft  :: !Coord
  , bbBotRight :: !Coord
  } deriving (Eq, Show, Ord, Read)


data ScaledImageConfig t = ScaledImageConfig
  { sicInitialSource :: T.Text
  , sicSetSource     :: Event t T.Text
  , sicTopLevelScale :: Dynamic t Double
  , sicTopLevelAttributes :: Dynamic t (Map T.Text T.Text)
  , sicCroppingAttributes :: Dynamic t (Map T.Text T.Text)
  , sicImgStyle :: Dynamic t T.Text
  , sicInitialOffset :: (Double, Double)
  , sicSetOffset :: Event t (Double, Double)
  , sicInitialScale :: Double
  , sicSetScale :: Event t Double
  , sicInitialBounding :: Maybe BoundingBox
  , sicSetBounding :: Event t (Maybe BoundingBox)
  }

instance Reflex t => Default (ScaledImageConfig t) where
  def = ScaledImageConfig "" never (constDyn 1) (constDyn mempty) (constDyn mempty)
    (constDyn "") (0,0) never 1 never def never


data ScaledImage t = ScaledImage
  { siImage             :: HTMLImageElement
  , siEl                :: El t
  , siImgEl             :: El t
  , siNaturalSize       :: Dynamic t (Int,Int)
  , screenToImageSpace  :: Dynamic t ((Double,Double) -> (Double, Double))
  , imageToScreenSpace  :: Dynamic t ((Double,Double) -> (Double, Double))
  }

-- | A widget supporting clipping, zooming, and translation of a source image.
--   Composed of
--     - a parent div fixed to the size of the source image,
--     - a cropping div
--     - the source image
scaledImage :: forall t m. MonadWidget t m => ScaledImageConfig t -> m (ScaledImage t)
scaledImage (ScaledImageConfig img0 dImg topScale topAttrs cropAttrs iStyle trans0 dTrans
             scale0 dScale bounding0 dBounding) = mdo
  pb <- getPostBuild

  firstLoad <- headE $ domEvent Load img
  naturalSize :: Dynamic t (Int,Int) <- holdDyn (1 :: Int, 1 :: Int) =<<
    performEvent (ffor firstLoad $ \() ->
                   (,) <$> (ImageElement.getNaturalWidth htmlImg)
                       <*> (ImageElement.getNaturalHeight htmlImg))

  let htmlImg = ImageElement.castToHTMLImageElement (_element_raw img)

  imgSrc     <- holdDyn img0 dImg
  bounding   <- holdDyn bounding0 dBounding
  trans      <- holdDyn trans0 dTrans
  innerScale <- holdDyn scale0 dScale
  let scale  = zipDynWith (*) innerScale topScale

      shiftScreenPix = mkShiftScreenPix <$> trans <*> bounding <*> scale

      parentAttrs = mkTopLevelAttrs <$> naturalSize <*> topAttrs <*> topScale

  (parentDiv, (img, imgSpace, screenSpace)) <- elDynAttr' "div" parentAttrs $ do

    let croppingAttrs = mkCroppingAttrs
          <$> naturalSize     <*> bounding  <*> scale
          <*>  shiftScreenPix <*> cropAttrs <*> iStyle

        imgAttrs = mkImgAttrs
          <$> imgSrc  <*> naturalSize <*> scale
          <*>  trans  <*> bounding

    -- The DOM element for the image itself
    (croppingDiv,img) <- elDynAttr' "div" croppingAttrs $
      fst <$> elDynAttr' "img" imgAttrs (return ())

    let imgSpace    = mkImgSpace <$> scale <*> shiftScreenPix
        screenSpace = mkScreenSpace <$> scale <*> shiftScreenPix
    return (img, imgSpace, screenSpace)

  return $ ScaledImage htmlImg parentDiv img naturalSize imgSpace screenSpace

  where
    mkTopLevelAttrs (naturalWid, naturalHei) topAttrs topScale =
      let defAttrs =
               "class" =: "scaled-image-top"
            <> "style" =: ("pointer-events:none;position:relative;overflow:hidden;width:"
                           <> (T.pack . show) (fI naturalWid * topScale)
                           <> "px;height:" <> (T.pack . show) (fI naturalHei * topScale) <> "px;")
      in Map.unionWith (<>) defAttrs topAttrs

    mkShiftScreenPix (natX, natY) bounding s =
      let (bX0,bY0) = maybe (0,0) (\(BoundingBox (Coord x y) _) -> (x,y)) bounding
      in  ((bX0 + natX)*s, (bY0 + natY)*s)

    mkCroppingAttrs (natWid, natHei) bnd scale (offXPx, offYPx) attrs extStyle =
     let sizingStyle = case bnd of
           Nothing ->
             let w :: Int = round $ fI natWid * scale
                 h :: Int = round $ fI natHei * scale
                 x :: Int = round $ offXPx
                 y :: Int = round $ offYPx
             in  "width:" <> (T.pack . show) w <> "px; height: " <> (T.pack . show) h <>
                 "px; left:" <> (T.pack . show) x <> "px;top:" <> (T.pack . show) y <> "px;"
           Just (BoundingBox (Coord x0 y0) (Coord x1 y1)) ->
             let w :: Int = round $ (x1 - x0) * scale
                 h :: Int = round $ (y1 - y0) * scale
                 x :: Int = round $ offXPx --(x0 <> offX) * scale
                 y :: Int = round $ offYPx -- (y0 <> offY) * scale
             in ("width:" <> (T.pack . show) w <> "px;height:" <> (T.pack . show) h <> "px;" <>
                      "left:"  <> (T.pack . show) x <> "px;top:" <> (T.pack . show) y <> "px;")

         baseStyle = "pointer-events:auto;position:relative;overflow:hidden;"

         style = case Map.lookup "style" attrs of
           Nothing -> baseStyle <> sizingStyle <> extStyle
           Just s  -> baseStyle <> sizingStyle <> s <> extStyle
     in Map.insert "style" style ("class" =: "cropping-div" <> attrs)

    mkImgAttrs src (naturalWid, naturalHei) scale (offX, offY) bb  =
     let posPart = case bb of
           Nothing ->
             let w :: Int = round $ fI naturalWid * scale
                 h :: Int = round $ fI naturalHei * scale
             in "width:" <> (T.pack . show) w <> "px; height: " <> (T.pack . show) h <> "px; position:absolute; left: 0px; top 0px;"
           Just (BoundingBox (Coord x0 y0) (Coord x1 y1)) ->
             let w :: Int = round $ fromIntegral naturalWid * scale
                 h :: Int = round $ fromIntegral naturalHei * scale
                 x :: Int = round $ negate x0 * scale
                 y :: Int = round $ negate y0 * scale
             in "pointer-events:auto;position:absolute;left:" <> (T.pack . show) x <> "px;top:" <> (T.pack . show) y <> "px;"
                <> "width:" <> (T.pack . show) w <> "px;"
      in   "src"   =: src
        <> "style" =: posPart

    mkImgSpace scale (imgOffX, imgOffY) = \(x,y) ->
      ((x - imgOffX) / scale, (y - imgOffY) / scale)

    mkScreenSpace scale (imgOffX, imgOffY) = \(x,y)->
      (scale * x + imgOffX, scale * y + imgOffY)

    relativizeEvent e f eventName shiftScreenPix = do
      let i = zipDynWith (,) f shiftScreenPix
      evs <- wrapDomEvent e (`on` eventName) $ do
        ev   <- event
        Just br <- getBoundingClientRect e
        xOff <- (r2 . negate) <$> getLeft br
        yOff <- (r2 . negate) <$> getTop  br
        liftM2 (,) (((<> xOff). fI) <$> getClientX ev) (((<> yOff) . fI) <$> getClientY ev)
      return $ attachWith (\(f,(dx,dy)) (x,y) -> f $ (x<>dx,y<>dy)) (current i) evs


divImgSpace' :: MonadWidget t m
             => Dynamic t ((Double,Double) -> (Double,Double))
             -> Dynamic t BoundingBox
             -> Dynamic t (Map T.Text T.Text)
             -> m a
             -> m (El t, a)
divImgSpace' toWidgetSpace bounding attrs children = do
  let widgetPos = zipDynWith
        (\f bb -> let (x0,y0) = f (coordX (bbTopLeft bb), coordY (bbTopLeft bb))
                      (x1,y1) = f (coordX (bbBotRight bb), coordY (bbBotRight bb))
                  in  ((x0,y0), (x1-x0, y1-y0))
        ) toWidgetSpace bounding

      attrs' = zipDynWith
        (\((x0,y0), (w,h)) ats ->
           let left = "left: "   <> (T.pack . show) x0  <> "px;"
               top  = "top: "    <> (T.pack . show) y0  <> "px;"
               wid  = "width: "  <> (T.pack . show) w <> "px;"
               hei  = "height: " <> (T.pack . show) h <> "px;"
               thisStyle = "position: absolute; " <> mconcat [left, top, wid, hei]
               style' = thisStyle <> fromMaybe "" (Map.lookup "style" ats)
           in (Map.insert "style" style' ats)
        ) widgetPos attrs
  elDynAttr' "div" attrs' children


divImgSpace :: MonadWidget t m
            => Dynamic t ((Double,Double) -> (Double,Double))
            -> Dynamic t BoundingBox
            -> Dynamic t (Map T.Text T.Text)
            -> m a
            -> m a
divImgSpace f b a c = fmap snd $ divImgSpace' f b a c

fI :: (Integral a, RealFrac b) => a -> b
fI = fromIntegral

r2 :: (Real a, Fractional b) => a -> b
r2 = realToFrac

#ifndef ghcjs_HOST_OS
fromJSValUnchecked = error ""
toJSVal = error ""

data CanvasRenderingContext2D
data ImageData
data ClientRect = ClientRect
  deriving Show

getContext :: MonadIO m => HTMLCanvasElement -> T.Text -> m CanvasRenderingContext2D
getContext = error "getContext only available in ghcjs"

getImageData :: CanvasRenderingContext2D -> Float -> Float -> Float -> Float -> IO (Maybe ImageData)
getImageData = error "getImageData only available in ghcjs"

castToHTMLCanvasElement :: IsGObject obj => obj -> HTMLCanvasElement
castToHTMLCanvasElement = error "castToHTMLCanvasElement only available in ghcjs"

save :: MonadIO m => CanvasRenderingContext2D -> m ()
save = error "save only available in ghcjs"

restore :: MonadIO m => CanvasRenderingContext2D -> m ()
restore = error "restore only available in ghcjs"

getBoundingClientRect :: MonadIO m => a -> m (Maybe ClientRect)
getBoundingClientRect = error "getBoundingClientRect only available in ghcjs"

getTop :: MonadIO m => ClientRect -> m Float
getTop = error "getTop only available in ghcjs"

getLeft :: MonadIO m => ClientRect -> m Float
getLeft = error "getLeft only available in ghcjs"

getWidth :: MonadIO m => ClientRect -> m Float
getWidth = error "getWidth only available in ghcjs"

getHeight :: MonadIO m => ClientRect -> m Float
getHeight = error "getHeight only available in ghcjs"

#endif

wheelEvents x = do
  wrapDomEvent (_element_raw x) (`on` E.wheel) $ do
    ev <- event
    delY <- getDeltaY ev
    Just br <- getBoundingClientRect (_element_raw x)
    xOff <- fmap (r2 . negate) (getLeft br)
    yOff <- fmap (r2 . negate) (getTop  br)
    cX   <- getClientX ev
    cY   <- getClientY ev
    return (delY, (fI cX + xOff, fI cY + yOff ))

