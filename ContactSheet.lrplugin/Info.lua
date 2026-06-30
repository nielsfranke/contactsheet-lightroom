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

  VERSION = { major = 0, minor = 4, revision = 0, build = 0 },
}
