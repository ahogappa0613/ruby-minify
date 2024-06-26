def hoge
  yield 1
end

hoge do |a|
  p a
end
