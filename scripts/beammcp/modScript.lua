-- Auto-load the beammcp MCP server when BeamNG starts. The modmanager dofile()s every
-- /scripts/**/modScript.lua at startup; marking the extension "manual" makes
-- loadManualUnloadExtensions() load it and keep it alive across level/Lua reloads.
-- (Cleaner than extensions.load("beammcp") here, which logs a deprecation warning.)
setExtensionUnloadMode("beammcp", "manual")
