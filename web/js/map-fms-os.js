OpenLayers.Layer.OSFMS = OpenLayers.Class(OpenLayers.Layer.BingUK, {
    get_urls: function(bounds, z) {
        var in_uk = this.in_uk(bounds.getCenterLonLat());
        if (z >= 16 && in_uk) {
            var url = fixmystreet.os_url.replace('%s', fixmystreet.os_layer) + "/${z}/${x}/${y}.png";
            if (fixmystreet.os_key) {
                url += "?key=" + fixmystreet.os_key;
            }
            return [url];
        }
        return OpenLayers.Layer.BingUK.prototype.get_urls.apply(this, arguments);
    },

    CLASS_NAME: "OpenLayers.Layer.OSFMS"
});

fixmystreet.layer_options = [
  { map_type: OpenLayers.Layer.OSFMS },
  { map_type: OpenLayers.Layer.BingAerial }
];
