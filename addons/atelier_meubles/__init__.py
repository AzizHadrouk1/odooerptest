from . import models


def post_init_hook(env):
    """Enable the default warehouse's make-to-order route on a fresh install."""
    env.ref("stock.route_warehouse0_mto").active = True
