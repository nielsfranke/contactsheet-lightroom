--[[
  ContactSheet — Lightroom Classic export/publish plugin
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 Niels Franke

  Plugin manifest. Registers a single Export Service Provider ("ContactSheet")
  that appears in File > Export and as a Publish Service. The provider renders
  via Lightroom's normal export pipeline and uploads the finished files to a
  ContactSheet instance over its REST API using a personal access token.
]]

return {
  LrSdkVersion = 12.0,
  LrSdkMinimumVersion = 6.0, -- Lightroom 6 / CC and later

  LrToolkitIdentifier = 'cc.nielsbox.contactsheet.lightroom',
  LrPluginName = 'ContactSheet',
  LrPluginInfoUrl = 'https://github.com/nielsfranke/contactsheet-lightroom',

  LrExportServiceProvider = {
    title = 'ContactSheet',
    file = 'CSExportServiceProvider.lua',
  },

  -- Library > Plug-in Extras: read client picks (flags/ratings) back into the catalog.
  -- Sync = publish-service collections (matched by remote id). Import = any gallery,
  -- incl. plain-Export/web ones (matched by filename against the current selection).
  LrLibraryMenuItems = {
    {
      title = 'Sync client picks from ContactSheet',
      file = 'CSSyncPicks.lua',
    },
    {
      title = 'Import client picks from a gallery…',
      file = 'CSImportPicks.lua',
    },
  },

  VERSION = { major = 0, minor = 9, revision = 1, build = 0 },
}
