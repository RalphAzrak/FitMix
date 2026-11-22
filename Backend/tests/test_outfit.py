from .test_avatar import JPEG, PNG, Recorder, client


def image(data=JPEG):
    return ("garment.jpg", data, "image/jpeg")


def test_styles_the_same_avatar_with_all_four_slots_in_a_single_edit():
    recorder = Recorder()
    response = client(recorder).post("/v1/avatar-outfit", files={
        "shoes": image(), "outerwear": image(), "portrait": image(),
        "pants": image(), "tshirt": image(),
    })

    assert response.status_code == 200 and response.content == PNG
    assert response.headers["cache-control"] == "no-store"
    assert len(recorder.calls) == 1
    images, prompt = recorder.calls[0]
    assert [name for name, _, _ in images] == [
        "portrait.jpeg", "tshirt.jpeg", "pants.jpeg", "shoes.jpeg", "outerwear.jpeg"
    ]
    assert "same person" in prompt
    assert "recognizable face" in prompt
    assert "Wear the T-shirt under the jacket or hoodie" in prompt


def test_applies_only_the_selected_slot():
    recorder = Recorder()
    response = client(recorder).post("/v1/avatar-outfit", files={"portrait": image(), "shoes": image()})

    assert response.status_code == 200
    images, prompt = recorder.calls[0]
    assert [name for name, _, _ in images] == ["portrait.jpeg", "shoes.jpeg"]
    assert "Image 2 shows the shoes" in prompt
    assert "unselected slots" in prompt


def test_requires_a_garment_and_rejects_an_invalid_photo_before_generation():
    recorder = Recorder()
    service = client(recorder)
    assert service.post("/v1/avatar-outfit", files={"portrait": image()}).json()["error"]["code"] == "empty_outfit"
    response = service.post("/v1/avatar-outfit", files={"portrait": image(), "outerwear": image(b"not a JPEG")})
    assert response.json()["error"]["code"] == "invalid_image"
    assert not recorder.calls
