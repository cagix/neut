module Entity.Command where

import Entity.Config.Build qualified as Build
import Entity.Config.Check qualified as Check
import Entity.Config.Clean qualified as Clean
import Entity.Config.Create qualified as Create
import Entity.Config.Get qualified as Get
import Entity.Config.Release qualified as Release
import Entity.Config.Tidy qualified as Tidy
import Entity.Config.Version qualified as Version

data Command
  = Build Build.Config
  | Check Check.Config
  | Clean Clean.Config
  | Release Release.Config
  | Get Get.Config
  | Tidy Tidy.Config
  | Create Create.Config
  | ShowVersion Version.Config