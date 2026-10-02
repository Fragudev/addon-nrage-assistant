local _, ns = ...

-- Spanish (neutral, for Spain and Latin America). The key is the English text exactly as the code writes it;
-- keep the placeholders (%d, %s) in the same order. Developer output (/nrage debug) is not translated.
ns.Locale.Register("es", {
  -- Core/Init.lua
  ["disabled: you are not in a guild."] = "desactivado: no perteneces a una guild.",
  ["disabled: this addon is only for the Nrage guild."] = "desactivado: este addon es solo para la guild Nrage.",
  ["disabled: this addon is only for the Alliance."] = "desactivado: este addon es solo para la Alianza.",
  ["disabled: this addon is only for the PvP ruleset."] = "desactivado: este addon es solo para el reino PvP.",
  ["disabled: saved data comes from a newer version of the addon. Update the addon; your data was left untouched."] = "desactivado: los datos guardados son de una versión más reciente del addon. Actualiza el addon; tus datos no se han tocado.",

  -- UI/MinimapButton.lua
  ["usage: /nrage minimap [show | hide | reset]"] = "uso: /nrage minimap [show | hide | reset]",
  ["minimap button hidden. Type /nrage minimap show to bring it back."] = "botón del minimapa oculto. Escribe /nrage minimap show para recuperarlo.",
  ["minimap button shown. Drag it to move it around the minimap."] = "botón del minimapa visible. Arrástralo para moverlo alrededor del minimapa.",
  ["Left click: open the window"] = "Clic izquierdo: abrir la ventana",
  ["Right click: shortcuts and sync"] = "Clic derecho: atajos y sincronización",
  ["Drag: move this button"] = "Arrastrar: mover este botón",
})
