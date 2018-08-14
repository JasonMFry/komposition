{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedLabels           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RebindableSyntax           #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | A declarative GTK implementation of the 'UserInterface' protocol.
module FastCut.UserInterface.GtkInterface (runGtkUserInterface) where

import           FastCut.Prelude                                  hiding (state)
import qualified Prelude

import           Control.Monad                                    (void)
import           Control.Monad.Indexed                            ()
import           Control.Monad.Indexed.Trans
import           Control.Monad.Reader
import           Data.Row.Records                                 (Empty)
import           Data.String
import qualified Data.Text                                        as Text
import qualified GI.Gdk                                           as Gdk
import qualified GI.GLib.Constants                                as GLib
import           GI.Gtk                                           (AttrOp (..))
import qualified GI.Gtk.Declarative                               as Gtk
import           Motor.FSM                                        hiding ((:=))
import qualified Motor.FSM                                        as FSM
import           Pipes
import           Text.Printf

import           Control.Monad.Indexed.IO
import           FastCut.Progress
import           FastCut.UserInterface
import           FastCut.UserInterface.GtkInterface.EventListener
import           FastCut.UserInterface.GtkInterface.ImportView
import           FastCut.UserInterface.GtkInterface.LibraryView
import           FastCut.UserInterface.GtkInterface.TimelineView
import           FastCut.UserInterface.GtkInterface.View

data Env = Env
  { cssPath :: FilePath
  , screen  :: Gdk.Screen
  }

instance MonadIO m => IxMonadIO (GtkInterface m) where
  iliftIO = ilift . liftIO

newtype GtkInterface m i o a = GtkInterface
  { runGtkInterface :: FSM m i o a
  } deriving (IxFunctor, IxPointed, IxApplicative, IxMonad, MonadFSM, IxMonadTrans)

deriving instance Monad m => Functor (GtkInterface m i i)
deriving instance Monad m => Applicative (GtkInterface m i i)
deriving instance Monad m => Monad (GtkInterface m i i)

data GtkInterfaceState mode = GtkInterfaceState
  { window      :: Gtk.Window
  , allEvents   :: EventListener (Event mode)
  , keyMaps     :: KeyMaps
  , currentView :: View mode
  }

runUI :: IO () -> IO ()
runUI f = void (Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT (f *> return False))

unsubscribeView :: GtkInterfaceState a -> IO ()
unsubscribeView state = do
  unsubscribe (allEvents state)
  unsubscribe (viewEvents (currentView state))

initializeWindow :: Env -> Gtk.Markup -> IO Gtk.Window
initializeWindow Env { cssPath, screen } obj = do
  w <- newEmptyMVar
  runUI $ do
    window <- Gtk.windowNew Gtk.WindowTypeToplevel
    Gtk.windowSetTitle window "FastCut"
    Gtk.windowResize window 640 480
    void $ Gtk.onWidgetDestroy window Gtk.mainQuit

    cssProviderVar <- newMVar Nothing
    reloadCssProvider cssProviderVar

    void $ window `Gtk.onWidgetKeyPressEvent` \eventKey -> do
      keyVal <- Gdk.getEventKeyKeyval eventKey
      case keyVal of
        Gdk.KEY_F5 ->
          runUI
            $       reloadCssProvider cssProviderVar
            `catch` (\(e :: SomeException) -> print e)
        _ -> return ()
      return False

    windowStyle <- Gtk.widgetGetStyleContext window
    Gtk.styleContextAddClass windowStyle "fastcut"
    Gtk.widgetShowAll window
    Gtk.containerAdd window =<< Gtk.toWidget =<< Gtk.create obj
    Gtk.widgetShowAll window
    putMVar w window
  takeMVar w
 where
  cssPriority = fromIntegral Gtk.STYLE_PROVIDER_PRIORITY_USER
  reloadCssProvider var = do
    cssProvider <- Gtk.cssProviderNew
    Gtk.cssProviderLoadFromPath cssProvider (Text.pack cssPath)
    Gtk.styleContextAddProviderForScreen screen cssProvider cssPriority
    takeMVar var >>= \case
      Just p  -> Gtk.styleContextRemoveProviderForScreen screen p
      Nothing -> return ()
    putMVar var (Just cssProvider)

render :: View m' -> GtkInterfaceState m -> IO ()
render newView state = runUI
  (patchBox (window state) (markup (currentView state)) (markup newView))
 where
  patchBox :: Gtk.Window -> Gtk.Markup -> Gtk.Markup -> IO ()
  patchBox w o1 o2 = case Gtk.patch o1 o2 of
    Gtk.Modify f -> Gtk.containerGetChildren w >>= \case
      []    -> return ()
      (c:_) -> do
        f =<< Gtk.toWidget c
        Gtk.widgetShowAll w
    Gtk.Replace createNew -> do
      Gtk.containerForall w (Gtk.containerRemove w)
      newWidget <- createNew
      Gtk.containerAdd w newWidget
      Gtk.widgetShowAll w
    Gtk.Keep -> return ()

renderFirst
  :: IO (View a) -> SMode a -> KeyMaps -> Env -> IO (GtkInterfaceState a)
renderFirst createView mode keyMaps env = do
  view      <- createView
  w         <- initializeWindow env (markup view)
  allEvents <-
    subscribeKeyEvents w >>= applyKeyMap (keyMaps mode) >>= mergeEvents
      (viewEvents view)
  pure GtkInterfaceState
    { window      = w
    , currentView = view { viewEvents = allEvents }
    , ..
    }

switchView
  :: View b -> SMode b -> GtkInterfaceState a -> IO (GtkInterfaceState b)
switchView newView newMode state = do
  unsubscribeView state
  render newView state
  allEvents <-
    subscribeKeyEvents (window state)
    >>= applyKeyMap (keyMaps state newMode)
    >>= mergeEvents (viewEvents newView)
  pure GtkInterfaceState
    { window      = window state
    , currentView = newView
    , keyMaps     = keyMaps state
    , ..
    }

switchView'
  :: (MonadFSM m, IxMonadIO m)
  => Name n
  -> IO (View b)
  -> SMode b
  -> Actions
       m
       '[(FSM.:=) n (GtkInterfaceState a !--> GtkInterfaceState b)]
       r
       ()
switchView' n view newMode = FSM.get n
  >>>= \s -> iliftIO (view >>= \v -> switchView v newMode s) >>>= FSM.enter n

printFractionAsPercent :: Double -> Text
printFractionAsPercent fraction =
  toS (printf "%.0f%%" (fraction * 100) :: Prelude.String)

instance (MonadReader Env m, MonadIO m) => UserInterface (GtkInterface m) where
  type State (GtkInterface m) = GtkInterfaceState

  start n keyMaps project focus =
    ilift ask
    >>>= iliftIO . renderFirst (timelineView project focus) STimelineMode keyMaps
    >>>= FSM.new n

  updateTimeline n project focus =
    switchView' n (timelineView project focus) STimelineMode

  returnToTimeline n project focus =
    switchView' n (timelineView project focus) STimelineMode

  enterLibrary n assets idx =
    switchView' n (libraryView assets idx) SLibraryMode

  updateLibrary n clips idx =
    switchView' n (libraryView clips idx) SLibraryMode

  enterImport n =
    switchView' n importView SImportMode

  nextEvent n = FSM.get n >>>= iliftIO . readEvent . allEvents

  beep _ = iliftIO (runUI Gdk.beep)

  dialog n title message choices =
    FSM.get n >>>= \s -> iliftIO $ do
    response <- newEmptyMVar
    runUI $ do
      d <- Gtk.new Gtk.Dialog []
      Gtk.windowSetTitle d title
      Gtk.windowSetTransientFor d (Just (window s))
      Gtk.windowSetModal d True
      forM_ choices $ \choice ->
        void (Gtk.dialogAddButton d (toButtonLabel choice) (fromIntegral (fromEnum choice)))
      content <- Gtk.dialogGetContentArea d
      contentStyle <- Gtk.widgetGetStyleContext content
      Gtk.styleContextAddClass contentStyle "dialog-container"
      label <- Gtk.new Gtk.Label []
      Gtk.labelSetLabel label message
      Gtk.boxPackStart content label True True 10
      Gtk.widgetShowAll content
      Gtk.dialogRun d >>= \case
        r | r < 0 -> putMVar response Nothing
        r -> putMVar response (Just (toEnum (fromIntegral r)))
      Gtk.widgetDestroy d
    takeMVar response

  chooseFile n mode title defaultDir =
    FSM.get n >>>= \s -> iliftIO $ do
    response <- newEmptyMVar
    runUI $ do
      d <- Gtk.new Gtk.FileChooserNative []
      chooser <- Gtk.toFileChooser d
      void (Gtk.fileChooserSetCurrentFolder chooser defaultDir)
      Gtk.fileChooserSetDoOverwriteConfirmation chooser True
      Gtk.fileChooserSetAction chooser (modeToAction mode)
      Gtk.nativeDialogSetTitle d title
      Gtk.nativeDialogSetTransientFor d (Just (window s))
      Gtk.nativeDialogSetModal d True
      res <- Gtk.nativeDialogRun d
      case toEnum (fromIntegral res) of
        Gtk.ResponseTypeAccept -> Gtk.fileChooserGetFilename d >>= putMVar response
        Gtk.ResponseTypeCancel -> putMVar response Nothing
        -- Loads of other cases:
        _ -> putMVar response Nothing
      Gtk.nativeDialogDestroy d
    takeMVar response
    where
      modeToAction = \case
        Open ->  Gtk.FileChooserActionOpen
        Save -> Gtk.FileChooserActionSave

  progressBar n title producer =
    FSM.get n >>>= \s -> iliftIO $ do
      response <- newEmptyMVar
      runUI $ do
        d <- Gtk.new Gtk.Dialog [#title := title, #transientFor := window s, #modal := True]
        content <- Gtk.dialogGetContentArea d
        pb <- Gtk.new Gtk.ProgressBar [#showText := True]
        contentStyle <- Gtk.widgetGetStyleContext content
        Gtk.styleContextAddClass contentStyle "progress-bar-container"
        let updateProgress = forever $ do
              ProgressUpdate fraction <- await
              liftIO . runUI $
                Gtk.set pb [#fraction := fraction, #text := printFractionAsPercent fraction]
        #add content pb
        #showAll d

        jobResult <- newEmptyMVar
        tid <- forkIO $ do
          result <- Pipes.runEffect (producer >-> updateProgress)
          putMVar jobResult result
          runUI (#destroy d)

        r <- #run d
        when (r < 0) (#destroy d)

        tryReadMVar jobResult >>= \case
          Just result -> putMVar response (Just result)
          Nothing -> do
            killThread tid
            putMVar response Nothing
      takeMVar response

  exit n =
    (FSM.get n >>>= iliftIO . unsubscribeView)
    >>> iliftIO Gtk.mainQuit
    >>> delete n

runGtkUserInterface
  :: FilePath
  -> GtkInterface (ReaderT Env IO) Empty Empty ()
  -> IO ()
runGtkUserInterface cssPath ui = do
  void $ Gtk.init Nothing
  screen <- maybe (fail "No screen?!") return =<< Gdk.screenGetDefault

  void (forkIO (runReaderT (runFSM (runGtkInterface ui)) Env {..}))
  Gtk.main
