"""Opening geometry uses logical monitor work areas, not transient tiled sizes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('place', Path(__file__).resolve().parents[1] / 'bin/task-manager-place.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class Placement(unittest.TestCase):
    def monitor(self, **changes):
        return dict({'id':0, 'name':'HDMI-A-1', 'x':0, 'y':0, 'width':1920,
                     'height':1080, 'scale':1, 'transform':0, 'reserved':[0,26,0,0]}, **changes)

    def test_default_centered_below_bar(self):
        self.assertEqual(p.bounds(self.monitor(), 560, 640), {'x':680,'y':233,'w':560,'h':640})

    def test_old_fullscreen_preference_is_clamped_with_margin(self):
        self.assertEqual(p.bounds(self.monitor(),1920,1080), {'x':24,'y':50,'w':1872,'h':1006})

    def test_scale_offset_rotation_and_reservations(self):
        m=self.monitor(x=-1280,y=20,width=2560,height=1440,scale=2,reserved=[30,40,10,20])
        r=p.bounds(m,9000,9000)
        self.assertEqual(r,{'x':-1226,'y':84,'w':1192,'h':612})
        rotated=p.bounds(self.monitor(width=2560,height=1440,scale=2,transform=1),9000,9000)
        self.assertEqual((rotated['w'],rotated['h']),(672,1206))

    def test_small_screen_and_invalid_preferences_remain_bounded(self):
        r=p.bounds(self.monitor(width=320,height=240),560,640)
        self.assertEqual(r,{'x':24,'y':50,'w':272,'h':166})
        self.assertEqual(p.bounds(self.monitor(),'NaN','inf'), p.bounds(self.monitor(),560,640))

    def test_cursor_selects_scaled_monitor_and_falls_back_to_window(self):
        monitors=[self.monitor(),self.monitor(id=1,name='DP-1',x=1920,width=3840,height=2160,scale=2)]
        self.assertEqual(p.choose_monitor(monitors,{'x':2100,'y':100},{'monitor':0})['id'],1)
        self.assertEqual(p.choose_monitor(monitors,{}, {'monitor':1})['id'],1)

    def fake_ipc(self, after=None):
        first={'initialTitle':'Omarchy Task Manager','address':'0xabc','monitor':0,'floating':False,
               'at':[-2,-2],'size':[1920,1080]}
        final=dict(first,floating=True,at=[680,233],size=[560,640]) if after is None else after
        ipc=Mock(); count=[0]
        def query(topic):
            if topic=='clients':
                count[0]+=1
                return [first if count[0]==1 else final]
            return [self.monitor()] if topic=='monitors' else {'x':100,'y':100}
        ipc.hypr_query.side_effect=query
        ipc.valid_address.return_value=True
        ipc.hypr_dispatch.return_value=True
        return ipc

    def test_float_resize_move_then_confirm_actual_geometry(self):
        ipc=self.fake_ipc()
        with contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.place(ipc,560,640),0)
        commands=[c.args[0] for c in ipc.hypr_dispatch.call_args_list]
        self.assertIn('float',commands[0]);self.assertIn('resize',commands[2])
        self.assertIn('x = 680, y = 233',commands[3])
        self.assertTrue(all('address:0xabc' in c for c in commands))

    def test_geometry_not_settled_retries_instead_of_persisting_tiled_size(self):
        ipc=self.fake_ipc(after={'address':'0xabc','floating':True,'at':[-2,-2],'size':[1920,1080]})
        with contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.place(ipc,560,640),75)

    def test_already_floating_is_not_toggled_back_to_tiled(self):
        ipc=self.fake_ipc()
        original=ipc.hypr_query.side_effect
        def query(topic):
            result=original(topic)
            if topic=='clients' and result:result[0]['floating']=True
            return result
        ipc.hypr_query.side_effect=query
        with contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.place(ipc,560,640),0)
        self.assertEqual(ipc.hypr_dispatch.call_count,3)
        self.assertTrue(all('window.float' not in c.args[0] for c in ipc.hypr_dispatch.call_args_list))

    def test_no_window_never_dispatches(self):
        ipc=self.fake_ipc();ipc.hypr_query.side_effect=lambda topic: []
        self.assertEqual(p.place(ipc,560,640),75);ipc.hypr_dispatch.assert_not_called()


if __name__=='__main__':unittest.main()
