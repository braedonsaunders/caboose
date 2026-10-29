"""Pure acceptance oracle. Input pixels must come from a completed native readback."""
import hashlib


def verify_pixels(pixels, case, metadata):
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
        expected = case['gpuGeneratedArguments'] + [case['gpuCookie']]
        actual = metadata.get('gpu_feedback_words')
        if actual != expected:
            result.update(status='FAIL', error='GPU-to-CPU feedback missing or incorrect',
                          expected_feedback=expected, actual_feedback=actual)
    return result
