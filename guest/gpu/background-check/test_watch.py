# Unit tests for watch.py's verdict (python3 -m unittest discover -s guest/gpu/background-check).
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('watch', pathlib.Path(__file__).with_name('watch.py'))
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def timeline(n=40, gpu_at=None, **overrides):
    """A sampled playback every 0.25 s; `gpu_at` maps sample index to a new GPU process id."""
    samples, gpu = [], 100
    for i in range(n):
        if gpu_at and i in gpu_at: gpu = gpu_at[i]
        sample = dict(t=i * 0.25, timeOrigin=1.0, started=True, videoTime=i * 0.25, paused=False, ended=False,
                      error=0, decodedFrames=i * 8, droppedFrames=0, audioState='running', audioTime=i * 0.25,
                      frames=i * 15, gpu=gpu)
        for key, change in overrides.items():
            if i in change: sample[key] = change[i]
        samples.append(sample)
    return samples


class Verdict(unittest.TestCase):
    def test_continuous_playback_across_two_gpu_restarts_passes(self):
        result = watch.verdict(timeline(gpu_at={10: 200, 25: 300}), expect_gpu_restarts=2, presents=40)
        self.assertEqual(result['result'], 'PASS', result['reasons'])
        self.assertEqual(result['gpu_restarts'], 2)

    def test_a_reload_fails(self):
        result = watch.verdict(timeline(timeOrigin={30: 2.0}))
        self.assertIn('the page reloaded', result['reasons'])

    def test_a_video_stall_over_a_second_fails(self):
        frozen = {i: 2.5 for i in range(10, 16)}  # 1.5 s standing still
        result = watch.verdict(timeline(videoTime=frozen))
        self.assertTrue(any('video stood still' in r for r in result['reasons']), result['reasons'])

    def test_a_short_video_stall_passes(self):
        frozen = {i: 2.5 for i in range(10, 13)}  # 0.75 s
        self.assertEqual(watch.verdict(timeline(videoTime=frozen))['result'], 'PASS')

    def test_suspended_audio_fails(self):
        result = watch.verdict(timeline(audioState={20: 'suspended'}))
        self.assertIn('the audio context left the running state', result['reasons'])

    def test_missing_restarts_and_no_decode_after_the_change_fail(self):
        stuck = {i: 80 for i in range(10, 40)}
        result = watch.verdict(timeline(gpu_at={10: 200}, decodedFrames=stuck), expect_gpu_restarts=2, presents=0)
        self.assertIn('1 GPU process restarts, expected 2', result['reasons'])
        self.assertIn('no video frame was decoded after the last GPU process change', result['reasons'])
        self.assertIn('the broker logged no presents after the last GPU process change', result['reasons'])


if __name__ == '__main__':
    unittest.main()
