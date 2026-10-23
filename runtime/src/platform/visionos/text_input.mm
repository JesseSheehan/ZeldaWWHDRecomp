// visionOS host: typed text, as gfx/text_input_appkit.mm does on macOS.
//
// The game's text prompt (overlay/text_entry.h: the name of a new save file, the Wii U software keyboard)
// stays the overlay's own window, so a controller alone still types with its on-screen keyboard. While it
// shows, an all but invisible text field in the TV window is the first responder, which brings up the
// visionOS keyboard (or takes a paired hardware keyboard): committed text goes to text_entry::text, an
// input method's composition to text_entry::preedit, and Return, Backspace on an empty field, Escape and
// the arrows to the prompt as keys (overlay::key), as on the Mac.
//
// The settings menu's own text fields (text_entry::field) have no keyboard to read here: they open a
// system alert with a text field (overlay/extensions.h, set_text_input), and so does input::prompt_text,
// the fallback when the overlay cannot show the game's prompt.
#import <UIKit/UIKit.h>

#include <algorithm>
#include <functional>
#include <string>

#include "input.h"
#include "overlay/extensions.h"
#include "overlay/overlay.h"
#include "overlay/text_entry.h"
#include "platform/keycodes.h"
#include "runtime.h"

static void send_key(int code) {
    overlay::key(code, true, false, 0);
    overlay::key(code, false, false, 0);
}

@interface WWTextField : UITextField <UITextFieldDelegate>
@end

@implementation WWTextField
- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0, 0, 4, 4)];
    self.alpha = 0.02;  // hidden fields cannot become first responder; this one is not seen
    self.autocorrectionType = UITextAutocorrectionTypeNo;
    self.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.spellCheckingType = UITextSpellCheckingTypeNo;
    self.smartQuotesType = UITextSmartQuotesTypeNo;
    self.smartDashesType = UITextSmartDashesTypeNo;
    self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    self.returnKeyType = UIReturnKeyDone;
    self.delegate = self;
    [self addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
    return self;
}

// the field only ever holds what the keyboard has not committed yet
- (void)changed {
    if (UITextRange* marked = self.markedTextRange) {
        NSString* s = [self textInRange:marked];
        text_entry::preedit(s.length ? s.UTF8String : "");
        return;
    }
    NSString* s = self.text;
    text_entry::preedit("");
    if (s.length) text_entry::text(s.UTF8String);
    self.text = @"";
}

- (void)deleteBackward {
    if (self.text.length == 0) send_key(kVK_Delete);  // nothing composing: the prompt's Backspace
    else [super deleteBackward];
}

- (BOOL)textFieldShouldReturn:(UITextField*)field {
    (void)field;
    if (!self.markedTextRange) send_key(kVK_Return);
    return NO;
}

// a hardware keyboard's editing keys (the visionOS keyboard has Return and Backspace only)
static int editing_key(UIPress* p) {
    switch (p.key.keyCode) {
    case UIKeyboardHIDUsageKeyboardEscape: return kVK_Escape;
    case UIKeyboardHIDUsageKeyboardLeftArrow: return kVK_LeftArrow;
    case UIKeyboardHIDUsageKeyboardRightArrow: return kVK_RightArrow;
    case UIKeyboardHIDUsageKeyboardUpArrow: return kVK_UpArrow;
    case UIKeyboardHIDUsageKeyboardDownArrow: return kVK_DownArrow;
    case UIKeyboardHIDUsageKeyboardHome: return kVK_Home;
    case UIKeyboardHIDUsageKeyboardEnd: return kVK_End;
    case UIKeyboardHIDUsageKeyboardDeleteForward: return kVK_ForwardDelete;
    default: return -1;
    }
}
- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    if (self.markedTextRange) return [super pressesBegan:presses withEvent:event];
    NSMutableSet<UIPress*>* rest = [NSMutableSet set];
    for (UIPress* p in presses) {
        const int code = p.key ? editing_key(p) : -1;
        if (code >= 0) overlay::key(code, true, false, 0);
        else [rest addObject:p];
    }
    if (rest.count) [super pressesBegan:rest withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    NSMutableSet<UIPress*>* rest = [NSMutableSet set];
    for (UIPress* p in presses) {
        const int code = p.key ? editing_key(p) : -1;
        if (code >= 0) overlay::key(code, false, false, 0);
        else [rest addObject:p];
    }
    if (rest.count) [super pressesEnded:rest withEvent:event];
}
@end

namespace visionos {

static WWTextField* g_field;
static UIView* g_host_view;

static UIViewController* top_controller() {
    UIViewController* c = g_host_view.window.rootViewController;
    while (c.presentedViewController) c = c.presentedViewController;
    return c;
}

static NSString* ns(const std::u16string& s) { return [NSString stringWithCharacters:(const unichar*)s.data() length:s.size()]; }
static std::u16string u16(NSString* s) {
    std::u16string out(s.length, u'\0');
    [s getCharacters:(unichar*)out.data() range:NSMakeRange(0, s.length)];
    return out;
}

// a system alert with one text field; `done` once, on the main thread
static void alert_prompt(const std::u16string& initial, const std::u16string& hint, int max_len,
                         std::function<void(bool, std::u16string)> done) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* parent = top_controller();
        if (!parent) {
            LOG("[visionos] no window for the text prompt");
            done(false, initial);
            return;
        }
        UIAlertController* a = [UIAlertController alertControllerWithTitle:hint.empty() ? @"Enter text" : ns(hint)
                                                                   message:max_len > 0 ? [NSString stringWithFormat:@"Up to %d characters.", max_len] : nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField* f) {
            f.text = ns(initial);
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        auto finish = std::make_shared<std::function<void(bool, std::u16string)>>(done);
        __weak UIAlertController* weak = a;
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
            (*finish)(false, initial);
        }]];
        UIAlertAction* ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
            std::u16string t = u16(weak.textFields.firstObject.text ?: @"");
            if (max_len > 0 && (int)t.size() > max_len) t.resize(max_len);
            (*finish)(true, t);
        }];
        [a addAction:ok];
        a.preferredAction = ok;
        [parent presentViewController:a animated:YES completion:nil];
    });
}

// main thread, once the TV window's view exists (display_init)
// the TV window's view (it is a new one each time that window opens)
void text_input_attach(UIView* view) {
    if (!g_field || view == g_host_view) return;
    if (g_field.isFirstResponder) [g_field resignFirstResponder];
    [g_field removeFromSuperview];
    g_host_view = view;
    [view addSubview:g_field];
}

void text_input_init(UIView* view) {
    g_host_view = view;
    g_field = [[WWTextField alloc] init];
    [view addSubview:g_field];
    overlay::ext::set_text_input([](const text_entry::Request& r, text_entry::Done done) {
        alert_prompt(r.initial, r.hint, r.max_len, std::move(done));
    });
}

// main thread, with the controller polling: the keyboard comes up with the game's prompt and goes with it
void text_input_poll() {
    if (!g_field) return;
    const bool want = text_entry::active() && !text_entry::field_active() && !overlay::is_open();
    if (want == g_field.isFirstResponder) return;
    if (want) {
        g_field.text = @"";
        if ([g_field becomeFirstResponder]) LOG("[visionos] system keyboard up for the text prompt");
    } else {
        [g_field resignFirstResponder];
        g_field.text = @"";
        text_entry::preedit("");
    }
}

}  // namespace visionos

namespace input {
// the game's prompt when the overlay cannot show it (text_entry::start returned false)
void prompt_text(const std::u16string& initial, int max_len, std::function<void(bool ok, std::u16string text)> done) {
    visionos::alert_prompt(initial, u"", max_len, std::move(done));
}
}  // namespace input
