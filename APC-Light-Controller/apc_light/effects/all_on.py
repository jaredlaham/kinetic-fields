"""All On — every pad lit in one colour (port of apc_test_all_on.py)."""

from apc_light.engine.effect import ColorParam, Effect


class AllOn(Effect):
    name = "All On"
    category = "Static"
    description = "Every pad on in a single colour"
    animated = False
    order = 10
    params = [ColorParam("color", "Color", "#ffffff")]

    def update(self, ctx, frame):
        frame.fill(ctx.params["color"])
