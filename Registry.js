.pragma library

// Hands the running Service to the bar icon and the dropdown. Omarchy only
// looks up a plugin's service for widgets on its built-in bar; under a
// replacement bar the lookup returns nothing, so the plugin shares it here.
var service = null
