#include "ss_audio_backend.h"

#ifdef SPRITESTUDIO_GODOT_EXTENSION
#include <godot_cpp/core/class_db.hpp>
#else
#include "core/object/class_db.h"
#endif

void SpriteStudioAudioBackend::_bind_methods() {
    GDVIRTUAL_BIND(_play_audio, "payload", "ssab", "player");
}

void SpriteStudioAudioBackend::play_audio(const Dictionary &payload, const Ref<SSABResource> &ssab, Node *player) {
    GDVIRTUAL_CALL(_play_audio, payload, ssab, player);
}
