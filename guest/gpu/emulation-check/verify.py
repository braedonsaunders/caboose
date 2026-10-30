"""Pure acceptance oracle. Input pixels must come from a completed native readback."""
import hashlib


def verify_pixels(pixels, case, metadata, *, expected_seed=None):
    if len(pixels) != 128 * 64 * 4:
        return {'status': 'FAIL', 'error': 'Wrong readback size'}
    samples = []
    for sample in case['samples']:
        x, y = sample['xy']
        if not (0 <= x < 128 and 0 <= y < 64):
            return {'status': 'FAIL', 'error': 'Sample outside image'}
        offset = (y * 128 + x) * 4
        actual = list(pixels[offset:offset + 4])
        samples.append({'xy': [x, y], 'expected': sample['rgba'], 'actual': actual,
                        'pass': actual == sample['rgba']})
    result = {'status': 'PASS' if samples and all(s['pass'] for s in samples) else 'FAIL',
              'samples': samples, 'rgba_sha256': hashlib.sha256(pixels).hexdigest()}
    if case.get('requiresCPUFeedback'):
        seed = case['inputSeed'] if expected_seed is None else expected_seed
        if type(seed) is not int or not 0 <= seed <= 0xffffffff or seed % 4 != 3:
            return {'status': 'FAIL', 'error': 'Invalid feedback challenge'}
        if expected_seed is not None and metadata.get('feedback_seed') != seed:
            return {'status': 'FAIL', 'error': 'Renderer challenge does not match invocation'}
        expected = [3 + seed % 4, 1, 0, 0, seed ^ 0x6d2b79f5]
        actual = metadata.get('gpu_feedback_words')
        if actual != expected:
            result.update(status='FAIL', error='GPU-to-CPU feedback missing or incorrect',
                          expected_feedback=expected, actual_feedback=actual)
    return result
