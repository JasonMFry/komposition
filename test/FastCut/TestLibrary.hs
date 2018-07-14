{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# LANGUAGE OverloadedStrings #-}
module FastCut.TestLibrary where

import           FastCut.Prelude

import           FastCut.Composition
import           FastCut.Library

video4s = Clip () $ VideoAsset (AssetMetadata "1.mp4" 4)
video10s = Clip () $ VideoAsset (AssetMetadata "2.mp4" 10)
audio1s = Clip () $ AudioAsset (AssetMetadata "1.m4a" 1)
audio4s = Clip () $ AudioAsset (AssetMetadata "2.m4a" 4)
audio10s = Clip () $ AudioAsset (AssetMetadata "3.m4a" 10)
gap1s = Gap () 1
gap3s = Gap () 3
parallel1 = Parallel () [gap1s, video4s] [audio1s]
parallel2 = Parallel () [gap3s, video10s] [audio4s, audio10s]

seqWithTwoParallels = Sequence () [parallel1, parallel2]

timelineTwoParallels = Timeline () [Sequence () [], seqWithTwoParallels]