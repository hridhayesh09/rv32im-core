# Render a GDS layout to a PNG with KLayout, without opening a window. Run inside the OpenLane 2
# Nix shell:
#   klayout -zz -rd gds=<file.gds> -rd lyp=<layers.lyp> -rd out=<file.png> -r tools/layout_png.py
# (lyp: the PDK's layer colours, sky130A/libs.tech/klayout/tech/sky130A.lyp)
#
# Only the signal routing layers are shown (Sky130 li1 67/20, met1 68/20, met2 69/20, met3 70/20):
# the met4/met5 power grid covers everything else, and text labels are hidden.
import pya

SHOWN = {(67, 20), (68, 20), (69, 20), (70, 20)}

view = pya.LayoutView()
view.load_layout(gds, 0)                     # noqa: F821 (gds, lyp, out come from -rd)
view.load_layer_props(lyp)                   # noqa: F821
it = view.begin_layers()
while not it.at_end():
    lp = it.current()
    lp.visible = (lp.source_layer, lp.source_datatype) in SHOWN
    view.set_layer_properties(it, lp)
    it.next()
view.set_config("text-visible", "false")
view.set_config("background-color", "#000000")
view.max_hier()
view.zoom_fit()
view.save_image(out, 2400, 2400)             # noqa: F821
print(f"wrote {out}")                        # noqa: F821
