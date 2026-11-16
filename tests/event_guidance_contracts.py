import unittest

EXPECTED_GUIDANCE = "按 Event 流程处理：handoff 直接处理；收到审核方发来的、无需后续执行的普通通过判定 notice（如 summary 以「验收通过：」开头），只关闭该判定 Event，不回“已收到”回执；收到交付方回执或评审请求时，按 ref 审阅，对原发送方发出判定后关闭该交付 Event；要求返工/继续执行或带提交授权的 handoff 不适用普通通过 notice 的只关闭规则，仍按相应流程处理；commit/push/PR 等仍先等用户确认。"
OLD_GUIDANCE = "按 Event 流程处理：handoff 直接开工；判定只 event_done；commit/push/PR 等先等用户确认。"


def visible_text_lines(messages):
    for message in messages:
        if not isinstance(message, dict):
            continue
        content = message.get('content')
        if isinstance(content, str):
            yield from content.splitlines()
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'text':
                    text = block.get('text')
                    if isinstance(text, str):
                        yield from text.splitlines()


def has_complete_guidance(messages):
    return any(line == EXPECTED_GUIDANCE for line in visible_text_lines(messages))


class GuidanceContracts(unittest.TestCase):
    def test_probe_accepts_complete_visible_text_line(self):
        messages = [{'role': 'user', 'content': 'other line\n' + EXPECTED_GUIDANCE + '\nanother line'}]
        self.assertTrue(has_complete_guidance(messages))

    def test_probe_accepts_complete_text_block_line(self):
        messages = [{'role': 'user', 'content': [
            {'type': 'text', 'text': 'wrapper line\n' + EXPECTED_GUIDANCE + '\nEvent body'}
        ]}]
        self.assertTrue(has_complete_guidance(messages))

    def test_same_line_prefix_is_rejected(self):
        self.assertFalse(has_complete_guidance([{
            'role': 'user', 'content': 'prefix ' + EXPECTED_GUIDANCE
        }]))

    def test_same_line_suffix_is_rejected(self):
        self.assertFalse(has_complete_guidance([{
            'role': 'user', 'content': EXPECTED_GUIDANCE + ' suffix'
        }]))

    def test_old_guidance_is_rejected(self):
        self.assertFalse(has_complete_guidance([{'role': 'user', 'content': OLD_GUIDANCE}]))

    def test_truncated_guidance_is_rejected(self):
        self.assertFalse(has_complete_guidance([{'role': 'user', 'content': EXPECTED_GUIDANCE[:-1]}]))

    def test_missing_received_verdict_direction_is_rejected(self):
        line = EXPECTED_GUIDANCE.replace("收到审核方发来的、无需后续执行的普通通过判定 notice", "收到普通判定")
        self.assertFalse(has_complete_guidance([{'role': 'user', 'content': line}]))

    def test_missing_delivery_sender_direction_is_rejected(self):
        line = EXPECTED_GUIDANCE.replace("对原发送方发出判定后关闭该交付 Event", "关闭该交付 Event")
        self.assertFalse(has_complete_guidance([{'role': 'user', 'content': line}]))


if __name__ == "__main__":
    unittest.main()
